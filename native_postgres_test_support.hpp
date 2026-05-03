#pragma once

#include <cstdlib>
#include <string>

#include "doof_runtime.hpp"

namespace doof_postgres_test_support {

inline doof::Result<std::string, std::string> env(const std::string& name) {
    const char* value = std::getenv(name.c_str());
    if (value == nullptr) {
        return doof::Result<std::string, std::string>::failure("environment variable is not set");
    }

    return doof::Result<std::string, std::string>::success(std::string(value));
}

} // namespace doof_postgres_test_support