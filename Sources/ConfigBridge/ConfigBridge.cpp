#include "ConfigBridge.h"
#include "vendor/toml.hpp"
#include <cmath>
#include <cstring>
#include <sstream>
#include <stdexcept>

static void validate(const toml::node &node, size_t &count, size_t depth = 0) {
    if (++count > 250000 || depth > 64)
        throw std::runtime_error("The TOML file exceeds the conversion size or depth limit.");
    if (auto table = node.as_table()) {
        for (const auto &[key, value] : *table) validate(value, count, depth + 1);
    } else if (auto array = node.as_array()) {
        for (const auto &value : *array) validate(value, count, depth + 1);
    } else if (node.is_date() || node.is_time() || node.is_date_time()) {
        throw std::runtime_error("TOML date and time values need a text value before conversion to this format.");
    } else if (auto number = node.as_floating_point(); number && !std::isfinite(number->get())) {
        throw std::runtime_error("Non-finite numbers cannot be converted to this format.");
    }
}

extern "C" char *rc_toml_json(const char *input, size_t length, int *success) {
    *success = 0;
    try {
        const auto table = toml::parse(std::string_view(input, length));
        size_t count = 0;
        validate(table, count);
        std::ostringstream output;
        output << toml::json_formatter(table);
        char *result = strdup(output.str().c_str());
        if (result) *success = 1;
        return result;
    } catch (const std::exception &error) {
        return strdup(error.what());
    } catch (...) {
        return strdup("The TOML parser failed.");
    }
}
