#pragma once

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include <libpq-fe.h>

#include "doof_runtime.hpp"

class NativeExecResult {
public:
    NativeExecResult(int32_t rowCount, std::string commandTag)
        : rowCount_(rowCount), commandTag_(std::move(commandTag)) {}

    int32_t rowCount() const {
        return rowCount_;
    }

    std::string commandTag() const {
        return commandTag_;
    }

private:
    int32_t rowCount_;
    std::string commandTag_;
};

using NativePostgresBlob = std::shared_ptr<std::vector<uint8_t>>;
using NativePostgresValue = std::variant<std::monostate, bool, int64_t, double, std::string, NativePostgresBlob>;
using NativePostgresRow = std::shared_ptr<doof::ordered_map<std::string, NativePostgresValue>>;

namespace {

constexpr unsigned int POSTGRES_BOOL_OID = 16;
constexpr unsigned int POSTGRES_BYTEA_OID = 17;
constexpr unsigned int POSTGRES_INT8_OID = 20;
constexpr unsigned int POSTGRES_INT2_OID = 21;
constexpr unsigned int POSTGRES_INT4_OID = 23;
constexpr unsigned int POSTGRES_TEXT_OID = 25;
constexpr unsigned int POSTGRES_FLOAT4_OID = 700;
constexpr unsigned int POSTGRES_FLOAT8_OID = 701;
constexpr unsigned int POSTGRES_NUMERIC_OID = 1700;
constexpr unsigned int POSTGRES_VARCHAR_OID = 1043;

std::string trimPostgresMessage(const std::string& text) {
    size_t end = text.size();
    while (end > 0) {
        const char ch = text[end - 1];
        if (ch == '\n' || ch == '\r' || ch == '\t' || ch == ' ') {
            --end;
            continue;
        }
        break;
    }
    return text.substr(0, end);
}

std::string encodePostgresError(const std::string& code, const std::string& message, const std::string& detail = std::string()) {
    return code + "|" + trimPostgresMessage(message) + "|" + trimPostgresMessage(detail);
}

doof::Result<void, std::string> postgresOk() {
    return doof::Result<void, std::string>::success();
}

bool tryParseInt64(const std::string& text, int64_t& value) {
    try {
        size_t processed = 0;
        const long long parsed = std::stoll(text, &processed, 10);
        if (processed != text.size()) {
            return false;
        }
        value = static_cast<int64_t>(parsed);
        return true;
    } catch (...) {
        return false;
    }
}

bool tryParseDouble(const std::string& text, double& value) {
    char* end = nullptr;
    const double parsed = std::strtod(text.c_str(), &end);
    if (end == nullptr || *end != '\0') {
        return false;
    }
    value = parsed;
    return true;
}

int32_t parseRowCount(PGresult* result) {
    if (result == nullptr) {
        return 0;
    }

    if (PQresultStatus(result) == PGRES_TUPLES_OK) {
        const int tuples = PQntuples(result);
        if (tuples < 0) {
            return 0;
        }
        return tuples;
    }

    const char* tuples = PQcmdTuples(result);
    if (tuples == nullptr || *tuples == '\0') {
        return 0;
    }

    int64_t parsed = 0;
    if (!tryParseInt64(tuples, parsed)) {
        return 0;
    }
    if (parsed > static_cast<int64_t>(std::numeric_limits<int32_t>::max())) {
        return std::numeric_limits<int32_t>::max();
    }
    if (parsed < static_cast<int64_t>(std::numeric_limits<int32_t>::min())) {
        return std::numeric_limits<int32_t>::min();
    }
    return static_cast<int32_t>(parsed);
}

std::shared_ptr<NativeExecResult> makeExecResult(PGresult* result) {
    const char* command = result != nullptr ? PQcmdStatus(result) : nullptr;
    return std::make_shared<NativeExecResult>(parseRowCount(result), command != nullptr ? std::string(command) : std::string());
}

} // namespace

class NativePostgresStatement;

class NativePostgresDatabase : public std::enable_shared_from_this<NativePostgresDatabase> {
public:
    static doof::Result<std::shared_ptr<NativePostgresDatabase>, std::string> open(const std::string& connectionString) {
        auto database = std::make_shared<NativePostgresDatabase>();
        if (database->openInternal(connectionString) != CONNECTION_OK) {
            return doof::Result<std::shared_ptr<NativePostgresDatabase>, std::string>::failure(database->notOpenError());
        }
        return doof::Result<std::shared_ptr<NativePostgresDatabase>, std::string>::success(database);
    }

    NativePostgresDatabase() = default;

    ~NativePostgresDatabase() {
        if (conn_ != nullptr) {
            PQfinish(conn_);
            conn_ = nullptr;
        }
    }

    doof::Result<std::shared_ptr<NativeExecResult>, std::string> exec(const std::string& sql) {
        if (conn_ == nullptr) {
            return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::failure(notOpenError());
        }

        PGresult* result = PQexec(conn_, sql.c_str());
        if (result == nullptr) {
            return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::failure(connectionError("failed to execute SQL"));
        }

        const ExecStatusType status = PQresultStatus(result);
        if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
            const std::string error = resultError(result, "failed to execute SQL");
            PQclear(result);
            return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::failure(error);
        }

        auto execResult = makeExecResult(result);
        PQclear(result);
        return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::success(execResult);
    }

    doof::Result<std::shared_ptr<NativePostgresStatement>, std::string> prepare(const std::string& sql);

    doof::Result<void, std::string> close() {
        if (conn_ == nullptr) {
            return postgresOk();
        }

        PQfinish(conn_);
        conn_ = nullptr;
        return postgresOk();
    }

    PGconn* rawConn() const {
        return conn_;
    }

    std::string notOpenError() const {
        return openError_.value_or(encodePostgresError(std::string(), "database is not open"));
    }

    std::string connectionError(const std::string& fallback) const {
        if (conn_ != nullptr) {
            const char* message = PQerrorMessage(conn_);
            if (message != nullptr && *message != '\0') {
                return encodePostgresError(std::string(), message);
            }
        }
        return encodePostgresError(std::string(), fallback);
    }

    std::string resultError(PGresult* result, const std::string& fallback) const {
        const char* code = result != nullptr ? PQresultErrorField(result, PG_DIAG_SQLSTATE) : nullptr;
        const char* message = result != nullptr ? PQresultErrorField(result, PG_DIAG_MESSAGE_PRIMARY) : nullptr;
        const char* detail = result != nullptr ? PQresultErrorField(result, PG_DIAG_MESSAGE_DETAIL) : nullptr;

        std::string messageText;
        if (message != nullptr && *message != '\0') {
            messageText = message;
        } else if (result != nullptr) {
            const char* fallbackMessage = PQresultErrorMessage(result);
            if (fallbackMessage != nullptr && *fallbackMessage != '\0') {
                messageText = fallbackMessage;
            }
        }
        if (messageText.empty()) {
            messageText = fallback;
        }

        return encodePostgresError(
            code != nullptr ? std::string(code) : std::string(),
            messageText,
            detail != nullptr ? std::string(detail) : std::string()
        );
    }

private:
    int openInternal(const std::string& connectionString) {
        connectionString_ = connectionString;
        PGconn* raw = PQconnectdb(connectionString.c_str());
        if (raw == nullptr) {
            openError_ = encodePostgresError(std::string(), "failed to allocate postgres connection");
            return CONNECTION_BAD;
        }

        if (PQstatus(raw) != CONNECTION_OK) {
            openError_ = encodePostgresError(std::string(), PQerrorMessage(raw));
            PQfinish(raw);
            return CONNECTION_BAD;
        }

        conn_ = raw;
        openError_ = std::nullopt;
        return CONNECTION_OK;
    }

    std::string nextStatementName() {
        const uint64_t nextId = ++nextStatementId_;
        return "doof_stmt_" + std::to_string(nextId);
    }

    PGconn* conn_ = nullptr;
    std::string connectionString_;
    std::optional<std::string> openError_;
    inline static std::atomic<uint64_t> nextStatementId_{0};

    friend class NativePostgresStatement;
};

class NativePostgresStatement {
public:
    NativePostgresStatement(
        std::shared_ptr<NativePostgresDatabase> database,
        std::string name,
        std::string sql,
        int32_t parameterCount
    )
        : database_(std::move(database)),
          name_(std::move(name)),
          sql_(std::move(sql)),
          parameterCount_(parameterCount),
          params_(parameterCount > 0 ? static_cast<size_t>(parameterCount) : 0) {}

    ~NativePostgresStatement() {
        finalizeBestEffort();
    }

    doof::Result<void, std::string> bindText(int32_t index, const std::string& value) {
        return bindTextValue(index, value);
    }

    doof::Result<void, std::string> bindBool(int32_t index, bool value) {
        return bindTextValue(index, value ? "true" : "false");
    }

    doof::Result<void, std::string> bindInt(int32_t index, int32_t value) {
        return bindTextValue(index, std::to_string(value));
    }

    doof::Result<void, std::string> bindLong(int32_t index, int64_t value) {
        return bindTextValue(index, std::to_string(value));
    }

    doof::Result<void, std::string> bindDouble(int32_t index, double value) {
        std::ostringstream buffer;
        buffer.precision(std::numeric_limits<double>::max_digits10);
        buffer << value;
        return bindTextValue(index, buffer.str());
    }

    doof::Result<void, std::string> bindBlob(int32_t index, const NativePostgresBlob& value) {
        const auto error = checkedIndexError(index);
        if (error.has_value()) {
            return doof::Result<void, std::string>::failure(error.value());
        }

        PGconn* conn = rawConn();
        if (conn == nullptr) {
            return doof::Result<void, std::string>::failure(notOpenError());
        }

        const auto& bytes = value != nullptr ? *value : emptyBlob();
        const unsigned char* source = bytes.empty() ? reinterpret_cast<const unsigned char*>("") : bytes.data();
        size_t escapedLength = 0;
        unsigned char* escaped = PQescapeByteaConn(conn, source, bytes.size(), &escapedLength);
        if (escaped == nullptr) {
            return doof::Result<void, std::string>::failure(database_->connectionError("failed to encode bytea parameter"));
        }

        const size_t offset = paramOffset(index);
        params_[offset].isBound = true;
        params_[offset].isNull = false;
        params_[offset].text.assign(
            reinterpret_cast<const char*>(escaped),
            escapedLength > 0 ? escapedLength - 1 : 0
        );
        PQfreemem(escaped);
        return postgresOk();
    }

    doof::Result<void, std::string> bindNull(int32_t index) {
        const auto error = checkedIndexError(index);
        if (error.has_value()) {
            return doof::Result<void, std::string>::failure(error.value());
        }

        const size_t offset = paramOffset(index);
        params_[offset].isBound = true;
        params_[offset].isNull = true;
        params_[offset].text.clear();
        return postgresOk();
    }

    doof::Result<bool, std::string> step() {
        if (finalized_) {
            return doof::Result<bool, std::string>::failure(encodePostgresError(std::string(), "statement is already finalized"));
        }

        if (!executed_) {
            PGconn* conn = rawConn();
            if (conn == nullptr) {
                return doof::Result<bool, std::string>::failure(notOpenError());
            }

            std::vector<const char*> values(params_.size(), nullptr);
            for (size_t index = 0; index < params_.size(); ++index) {
                if (params_[index].isBound && !params_[index].isNull) {
                    values[index] = params_[index].text.c_str();
                }
            }

            clearResult();
            result_ = PQexecPrepared(
                conn,
                name_.c_str(),
                parameterCount_,
                values.empty() ? nullptr : values.data(),
                nullptr,
                nullptr,
                0
            );
            executed_ = true;
            nextRowIndex_ = 0;
            currentRowIndex_ = -1;
            lastExecResult_.reset();

            if (result_ == nullptr) {
                return doof::Result<bool, std::string>::failure(database_->connectionError("failed to execute prepared statement"));
            }

            const ExecStatusType status = PQresultStatus(result_);
            if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
                return doof::Result<bool, std::string>::failure(database_->resultError(result_, "failed to execute prepared statement"));
            }

            lastExecResult_ = makeExecResult(result_);
        }

        if (result_ == nullptr) {
            return doof::Result<bool, std::string>::failure(encodePostgresError(std::string(), "statement has no active result"));
        }

        if (PQresultStatus(result_) != PGRES_TUPLES_OK) {
            currentRowIndex_ = -1;
            return doof::Result<bool, std::string>::success(false);
        }

        const int rowCount = PQntuples(result_);
        if (nextRowIndex_ >= rowCount) {
            currentRowIndex_ = -1;
            return doof::Result<bool, std::string>::success(false);
        }

        currentRowIndex_ = nextRowIndex_;
        ++nextRowIndex_;
        return doof::Result<bool, std::string>::success(true);
    }

    doof::Result<NativePostgresRow, std::string> readCurrentRow() {
        if (finalized_) {
            return doof::Result<NativePostgresRow, std::string>::failure(encodePostgresError(std::string(), "statement is already finalized"));
        }
        if (result_ == nullptr || PQresultStatus(result_) != PGRES_TUPLES_OK || currentRowIndex_ < 0) {
            return doof::Result<NativePostgresRow, std::string>::failure(encodePostgresError(std::string(), "statement is not positioned on a row"));
        }

        auto row = std::make_shared<doof::ordered_map<std::string, NativePostgresValue>>();
        const int count = PQnfields(result_);
        for (int index = 0; index < count; ++index) {
            const char* rawName = PQfname(result_, index);
            if (rawName == nullptr) {
                return doof::Result<NativePostgresRow, std::string>::failure(encodePostgresError(std::string(), "column has no name"));
            }

            std::string name(rawName);
            if (row->find(name) != row->end()) {
                return doof::Result<NativePostgresRow, std::string>::failure(encodePostgresError(std::string(), "duplicate column name: " + name));
            }

            if (PQgetisnull(result_, currentRowIndex_, index)) {
                row->insert_or_assign(name, NativePostgresValue(std::monostate{}));
                continue;
            }

            const char* rawValue = PQgetvalue(result_, currentRowIndex_, index);
            const int rawLength = PQgetlength(result_, currentRowIndex_, index);
            const std::string text(rawValue, rawLength);
            const unsigned int type = static_cast<unsigned int>(PQftype(result_, index));

            switch (type) {
                case POSTGRES_BOOL_OID:
                    row->insert_or_assign(name, NativePostgresValue(text == "t" || text == "true" || text == "1"));
                    break;
                case POSTGRES_INT2_OID:
                case POSTGRES_INT4_OID:
                case POSTGRES_INT8_OID: {
                    int64_t value = 0;
                    if (tryParseInt64(text, value)) {
                        row->insert_or_assign(name, NativePostgresValue(value));
                    } else {
                        row->insert_or_assign(name, NativePostgresValue(text));
                    }
                    break;
                }
                case POSTGRES_FLOAT4_OID:
                case POSTGRES_FLOAT8_OID:
                case POSTGRES_NUMERIC_OID: {
                    double value = 0.0;
                    if (tryParseDouble(text, value)) {
                        row->insert_or_assign(name, NativePostgresValue(value));
                    } else {
                        row->insert_or_assign(name, NativePostgresValue(text));
                    }
                    break;
                }
                case POSTGRES_BYTEA_OID: {
                    size_t decodedLength = 0;
                    unsigned char* decoded = PQunescapeBytea(reinterpret_cast<const unsigned char*>(rawValue), &decodedLength);
                    if (decoded == nullptr) {
                        return doof::Result<NativePostgresRow, std::string>::failure(encodePostgresError(std::string(), "failed to decode bytea column"));
                    }

                    auto bytes = std::make_shared<std::vector<uint8_t>>();
                    if (decodedLength > 0) {
                        bytes->assign(decoded, decoded + decodedLength);
                    }
                    PQfreemem(decoded);
                    row->insert_or_assign(name, NativePostgresValue(bytes));
                    break;
                }
                case POSTGRES_TEXT_OID:
                case POSTGRES_VARCHAR_OID:
                default:
                    row->insert_or_assign(name, NativePostgresValue(text));
                    break;
            }
        }

        return doof::Result<NativePostgresRow, std::string>::success(row);
    }

    doof::Result<void, std::string> reset() {
        if (finalized_) {
            return doof::Result<void, std::string>::failure(encodePostgresError(std::string(), "statement is already finalized"));
        }
        if (rawConn() == nullptr) {
            return doof::Result<void, std::string>::failure(notOpenError());
        }

        clearResult();
        executed_ = false;
        nextRowIndex_ = 0;
        currentRowIndex_ = -1;
        lastExecResult_.reset();
        for (auto& param : params_) {
            param.isBound = false;
            param.isNull = true;
            param.text.clear();
        }
        return postgresOk();
    }

    doof::Result<void, std::string> finalize() {
        if (finalized_) {
            return postgresOk();
        }

        clearResult();
        lastExecResult_.reset();
        finalized_ = true;

        PGconn* conn = rawConn();
        if (conn == nullptr || name_.empty()) {
            name_.clear();
            return postgresOk();
        }

        const std::string deallocateSql = "DEALLOCATE " + name_;
        PGresult* result = PQexec(conn, deallocateSql.c_str());
        name_.clear();
        if (result == nullptr) {
            return doof::Result<void, std::string>::failure(database_->connectionError("failed to deallocate prepared statement"));
        }

        const ExecStatusType status = PQresultStatus(result);
        if (status != PGRES_COMMAND_OK) {
            const std::string error = database_->resultError(result, "failed to deallocate prepared statement");
            PQclear(result);
            return doof::Result<void, std::string>::failure(error);
        }

        PQclear(result);
        return postgresOk();
    }

    doof::Result<std::shared_ptr<NativeExecResult>, std::string> executionResult() {
        if (lastExecResult_ == nullptr) {
            return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::failure(encodePostgresError(std::string(), "statement has no execution result"));
        }
        return doof::Result<std::shared_ptr<NativeExecResult>, std::string>::success(lastExecResult_);
    }

private:
    struct BoundParam {
        bool isBound = false;
        bool isNull = true;
        std::string text;
    };

    static const std::vector<uint8_t>& emptyBlob() {
        static const std::vector<uint8_t> empty;
        return empty;
    }

    std::optional<std::string> checkedIndexError(int32_t index) const {
        if (finalized_) {
            return encodePostgresError(std::string(), "statement is already finalized");
        }
        if (index <= 0 || index > parameterCount_) {
            return encodePostgresError(std::string(), "parameter index out of range for prepared statement");
        }
        return std::nullopt;
    }

    size_t paramOffset(int32_t index) const {
        return static_cast<size_t>(index - 1);
    }

    doof::Result<void, std::string> bindTextValue(int32_t index, const std::string& value) {
        const auto error = checkedIndexError(index);
        if (error.has_value()) {
            return doof::Result<void, std::string>::failure(error.value());
        }

        if (rawConn() == nullptr) {
            return doof::Result<void, std::string>::failure(notOpenError());
        }

        const size_t offset = paramOffset(index);
        params_[offset].isBound = true;
        params_[offset].isNull = false;
        params_[offset].text = value;
        return postgresOk();
    }

    void clearResult() {
        if (result_ != nullptr) {
            PQclear(result_);
            result_ = nullptr;
        }
    }

    PGconn* rawConn() const {
        if (database_ == nullptr) {
            return nullptr;
        }
        return database_->rawConn();
    }

    std::string notOpenError() const {
        if (database_ != nullptr) {
            return database_->notOpenError();
        }
        return encodePostgresError(std::string(), "database is not open");
    }

    void finalizeBestEffort() {
        if (finalized_) {
            clearResult();
            return;
        }

        clearResult();
        lastExecResult_.reset();
        finalized_ = true;

        PGconn* conn = rawConn();
        if (conn == nullptr || name_.empty()) {
            name_.clear();
            return;
        }

        const std::string deallocateSql = "DEALLOCATE " + name_;
        PGresult* result = PQexec(conn, deallocateSql.c_str());
        if (result != nullptr) {
            PQclear(result);
        }
        name_.clear();
    }

    std::shared_ptr<NativePostgresDatabase> database_;
    std::string name_;
    std::string sql_;
    int32_t parameterCount_ = 0;
    std::vector<BoundParam> params_;
    PGresult* result_ = nullptr;
    bool executed_ = false;
    int nextRowIndex_ = 0;
    int currentRowIndex_ = -1;
    std::shared_ptr<NativeExecResult> lastExecResult_;
    bool finalized_ = false;
};

inline doof::Result<std::shared_ptr<NativePostgresStatement>, std::string> NativePostgresDatabase::prepare(const std::string& sql) {
    if (conn_ == nullptr) {
        return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::failure(notOpenError());
    }

    const std::string statementName = nextStatementName();
    PGresult* prepared = PQprepare(conn_, statementName.c_str(), sql.c_str(), 0, nullptr);
    if (prepared == nullptr) {
        return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::failure(connectionError("failed to prepare SQL"));
    }

    if (PQresultStatus(prepared) != PGRES_COMMAND_OK) {
        const std::string error = resultError(prepared, "failed to prepare SQL");
        PQclear(prepared);
        return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::failure(error);
    }
    PQclear(prepared);

    PGresult* description = PQdescribePrepared(conn_, statementName.c_str());
    if (description == nullptr) {
        return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::failure(connectionError("failed to describe prepared statement"));
    }

    if (PQresultStatus(description) != PGRES_COMMAND_OK) {
        const std::string error = resultError(description, "failed to describe prepared statement");
        PQclear(description);
        return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::failure(error);
    }

    const int32_t parameterCount = PQnparams(description);
    PQclear(description);

    return doof::Result<std::shared_ptr<NativePostgresStatement>, std::string>::success(
        std::make_shared<NativePostgresStatement>(shared_from_this(), statementName, sql, parameterCount)
    );
}