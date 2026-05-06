#pragma once

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *comma_separator_utf8;
    size_t comma_separator_len;
    const char *colon_separator_utf8;
    size_t colon_separator_len;
} json_schema_separators_t;

typedef struct {
    int indent;
    int any_whitespace;
    int strict_mode;
    int max_whitespace_cnt;
    int has_separators;
    json_schema_separators_t separators;
} json_schema_compile_options_t;

void *grammar_compiler_new(
    void *tokenizer_info,
    int max_threads,
    int cache_enabled,
    int64_t max_memory_bytes
);

void grammar_compiler_free(void *grammar_compiler);

void *grammar_compiler_compile_ebnf(void *grammar_compiler, const char *ebnf_utf8, size_t ebnf_len);

void *grammar_compiler_compile_regex(
    void *grammar_compiler,
    const char *regex_utf8,
    size_t regex_len
);

void *grammar_compiler_compile_json_schema(
    void *grammar_compiler,
    const char *schema_utf8,
    size_t schema_len,
    const json_schema_compile_options_t *options
);

void *grammar_compiler_compile_structural_tag(
    void *grammar_compiler,
    const char *structural_tag_utf8,
    size_t structural_tag_len
);

int64_t compiled_grammar_vocab_size(void *compiled_grammar);

void compiled_grammar_free(void *compiled_grammar);

#ifdef __cplusplus
}
#endif
