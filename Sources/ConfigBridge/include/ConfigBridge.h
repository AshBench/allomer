#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// The caller frees the result with free(). On failure, the result is an error message.
char *rc_toml_json(const char *input, size_t length, int *success);
#ifdef __cplusplus
}
#endif
