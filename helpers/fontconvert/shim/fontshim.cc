// Bridges the pinned HarfBuzz subsetter and the pinned Google WOFF2 codec to the Rust helper.
// Every function returns a malloc'd buffer the caller releases with fontshim_free, or null.

#include <hb.h>
#include <hb-subset.h>
#include <woff2/decode.h>
#include <woff2/encode.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

uint8_t *copy_out(const uint8_t *data, size_t length, size_t *out_length) {
    uint8_t *buffer = static_cast<uint8_t *>(malloc(length ? length : 1));
    if (!buffer) return nullptr;
    memcpy(buffer, data, length);
    *out_length = length;
    return buffer;
}

}  // namespace

extern "C" void fontshim_free(uint8_t *pointer) { free(pointer); }

// Rewrites the font at its default design location: every axis pinned to its default, CFF2
// downgraded to CFF, variation and signature tables removed, every glyph and layout feature kept.
extern "C" uint8_t *fontshim_normalize(const uint8_t *data, size_t length, size_t *out_length) {
    if (length > UINT32_MAX) return nullptr;
    hb_blob_t *blob = hb_blob_create_or_fail(reinterpret_cast<const char *>(data),
                                             static_cast<unsigned>(length),
                                             HB_MEMORY_MODE_READONLY, nullptr, nullptr);
    if (!blob) return nullptr;
    hb_face_t *face = hb_face_create(blob, 0);
    hb_blob_destroy(blob);
    hb_subset_input_t *input = hb_subset_input_create_or_fail();
    if (!input) {
        hb_face_destroy(face);
        return nullptr;
    }
    // keep_everything assigns the whole flag word and clears the drop-table set, so it has to run
    // before the flags this conversion adds. Setting them first would silently lose them.
    hb_subset_input_keep_everything(input);
    hb_subset_input_set_flags(input, hb_subset_input_get_flags(input)
                                         | HB_SUBSET_FLAGS_RETAIN_GIDS
                                         | HB_SUBSET_FLAGS_DOWNGRADE_CFF2);
    hb_subset_input_pin_all_axes_to_default(input, face);
    // A digital signature cannot survive the rewrite below it.
    hb_set_add(hb_subset_input_set(input, HB_SUBSET_SETS_DROP_TABLE_TAG), HB_TAG('D', 'S', 'I', 'G'));
    hb_face_t *result = hb_subset_or_fail(face, input);
    hb_subset_input_destroy(input);
    hb_face_destroy(face);
    if (!result) return nullptr;
    hb_blob_t *produced = hb_face_reference_blob(result);
    unsigned produced_length = 0;
    const char *bytes = hb_blob_get_data(produced, &produced_length);
    uint8_t *copy = bytes ? copy_out(reinterpret_cast<const uint8_t *>(bytes), produced_length, out_length) : nullptr;
    hb_blob_destroy(produced);
    hb_face_destroy(result);
    return copy;
}

extern "C" uint8_t *fontshim_woff2_decode(const uint8_t *data, size_t length, size_t limit,
                                          size_t *out_length) {
    size_t expanded = woff2::ComputeWOFF2FinalSize(data, length);
    if (!expanded || expanded > limit) return nullptr;
    std::string output;
    output.resize(expanded);
    woff2::WOFF2StringOut sink(&output);
    sink.SetMaxSize(limit);
    if (!woff2::ConvertWOFF2ToTTF(data, length, &sink)) return nullptr;
    if (sink.Size() > limit) return nullptr;
    return copy_out(reinterpret_cast<const uint8_t *>(output.data()), sink.Size(), out_length);
}

extern "C" uint8_t *fontshim_woff2_encode(const uint8_t *data, size_t length, size_t *out_length) {
    size_t capacity = woff2::MaxWOFF2CompressedSize(data, length);
    if (!capacity) return nullptr;
    std::string output;
    output.resize(capacity);
    size_t written = capacity;
    if (!woff2::ConvertTTFToWOFF2(data, length, reinterpret_cast<uint8_t *>(&output[0]), &written)) {
        return nullptr;
    }
    if (written > capacity) return nullptr;
    return copy_out(reinterpret_cast<const uint8_t *>(output.data()), written, out_length);
}
