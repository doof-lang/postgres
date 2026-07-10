#pragma once

#include <cstdlib>
#include <string>

#include "doof_runtime.hpp"

namespace doof_postgres_test_support {

inline doof::Result<std::string, std::string> env(const std::string& name) {
    const char* value = std::getenv(name.c_str());
    if (value == nullptr) {
        return doof::Failure<std::string>{"environment variable is not set"};
    }

    return doof::Success<std::string>{std::string(value)};
}

} // namespace doof_postgres_test_support