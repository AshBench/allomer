/* SPDX-License-Identifier: MIT */
/* Included by the pinned tiffcp source, which already includes tiffiop.h. */

static const TIFFField interoperabilityFields[] = {
    {1, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_ASCII, 0, TIFF_SETGET_ASCII,
     FIELD_CUSTOM, 1, 0, "InteroperabilityIndex", NULL},
    {2, 4, 4, TIFF_UNDEFINED, 0, TIFF_SETGET_C0_UINT8,
     FIELD_CUSTOM, 1, 0, "InteroperabilityVersion", NULL}
};
static const TIFFFieldArray interoperability = {
    tfiatOther, 0, 2, (TIFFField *)interoperabilityFields
};

static int copyMetadataField(TIFF *in, TIFF *out, uint32_t tag)
{
    const TIFFField *field = TIFFFieldWithTag(in, tag);
    if (!field || field->field_type == TIFF_IFD || field->field_type == TIFF_IFD8)
        return 0; /* Directory offsets must be rewritten, never copied. */
    if (!TIFFFindField(out, tag, TIFF_ANY))
    {
        TIFFFieldInfo info = {tag, field->field_readcount, field->field_writecount,
                             field->field_type, FIELD_CUSTOM, 1,
                             field->field_passcount, "Metadata"};
        if (TIFFMergeFieldInfo(out, &info, 1) != 0)
            return 0;
    }
    const TIFFField *target = TIFFFieldWithTag(out, tag);
    if (field->set_get_field_type != target->set_get_field_type)
        return 0;
    void *values = NULL;
    if (TIFFFieldSetGetCountSize(field) == 2)
    {
        uint16_t count = 0;
        return TIFFGetField(in, tag, &count, &values) &&
               TIFFSetField(out, tag, count, values);
    }
    if (TIFFFieldSetGetCountSize(field) == 4)
    {
        uint32_t count = 0;
        return TIFFGetField(in, tag, &count, &values) &&
               TIFFSetField(out, tag, count, values);
    }
    if (field->set_get_field_type == TIFF_SETGET_ASCII ||
        (field->set_get_field_type >= TIFF_SETGET_C0_ASCII &&
         field->set_get_field_type <= TIFF_SETGET_C0_IFD8))
        return TIFFGetField(in, tag, &values) && TIFFSetField(out, tag, values);
#define COPY_METADATA_SCALAR(kind, type)                                      \
    case kind:                                                              \
    {                                                                       \
        type value;                                                         \
        return TIFFGetField(in, tag, &value) && TIFFSetField(out, tag, value); \
    }
    switch (field->set_get_field_type)
    {
        COPY_METADATA_SCALAR(TIFF_SETGET_UINT8, uint8_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_SINT8, int8_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_UINT16, uint16_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_SINT16, int16_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_UINT32, uint32_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_SINT32, int32_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_UINT64, uint64_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_SINT64, int64_t)
        COPY_METADATA_SCALAR(TIFF_SETGET_FLOAT, float)
        COPY_METADATA_SCALAR(TIFF_SETGET_DOUBLE, double)
        COPY_METADATA_SCALAR(TIFF_SETGET_INT, int)
        default:
            return 0;
    }
#undef COPY_METADATA_SCALAR
}

static int readMetadataDirectory(TIFF *in, uint64_t offset, int kind)
{
    if (kind == 0)
        return TIFFReadEXIFDirectory(in, offset);
    if (kind == 1)
        return TIFFReadGPSDirectory(in, offset);
    return TIFFReadCustomDirectory(in, offset, &interoperability);
}

static int copyMetadataDirectory(TIFF *in, TIFF *out, uint64_t offset, int kind,
                                 uint64_t *written, uint64_t ancestors[8], int depth)
{
    if (depth == 8)
        return 0;
    for (int i = 0; i < depth; ++i)
        if (ancestors[i] == offset)
            return 0;
    ancestors[depth] = offset;
    if (!readMetadataDirectory(in, offset, kind))
        return 0;

    uint64_t child = 0, childWritten = 0;
    const TIFFField *link = TIFFFindField(in, TIFFTAG_INTEROPERABILITYIFD, TIFF_ANY);
    if (link)
    {
        /* Unknown LONG fields use a counted array in the custom IFD reader. */
        if (link->set_get_field_type == TIFF_SETGET_C32_UINT32)
        {
            uint32_t count = 0, *values = NULL;
            if (TIFFGetField(in, TIFFTAG_INTEROPERABILITYIFD, &count, &values))
            {
                if (count != 1)
                    return 0;
                child = values[0];
            }
        }
        else if (link->set_get_field_type == TIFF_SETGET_IFD8)
        {
            TIFFGetField(in, TIFFTAG_INTEROPERABILITYIFD, &child);
        }
        else
            return 0;
    }
    if (child && (!copyMetadataDirectory(in, out, child, 2, &childWritten,
                                         ancestors, depth + 1) ||
                  !readMetadataDirectory(in, offset, kind)))
        return 0;

    int created = kind == 0 ? TIFFCreateEXIFDirectory(out) :
                  kind == 1 ? TIFFCreateGPSDirectory(out) :
                              TIFFCreateCustomDirectory(out, &interoperability);
    if (created != 0)
        return 0;
    for (int i = 0; i < TIFFGetTagListCount(in); ++i)
    {
        uint32_t tag = TIFFGetTagListEntry(in, i);
        if (tag != TIFFTAG_INTEROPERABILITYIFD && !copyMetadataField(in, out, tag))
        {
            TIFFError(TIFFFileName(in), "Cannot preserve metadata tag %u", tag);
            return 0;
        }
    }
    if (childWritten)
    {
        TIFFFieldInfo info = {TIFFTAG_INTEROPERABILITYIFD, 1, 1, TIFF_IFD8,
                             FIELD_CUSTOM, 1, 0, "InteroperabilityIFD"};
        if (TIFFMergeFieldInfo(out, &info, 1) != 0 ||
            !TIFFSetField(out, TIFFTAG_INTEROPERABILITYIFD, childWritten))
            return 0;
    }
    if (!TIFFWriteCustomDirectory(out, written))
        return 0;
    return TIFFCreateDirectory(out) == 0;
}

static int copyPageMetadata(TIFF *in, TIFF *out, tdir_t page)
{
    uint64_t sourcePage = TIFFCurrentDirOffset(in), exif = 0, gps = 0;
    uint64_t newExif = 0, newGPS = 0, ancestors[8];
    TIFFGetField(in, TIFFTAG_EXIFIFD, &exif);
    TIFFGetField(in, TIFFTAG_GPSIFD, &gps);
    if (!exif && !gps)
        return 1;
    if ((exif && !copyMetadataDirectory(in, out, exif, 0, &newExif, ancestors, 0)) ||
        (gps && !copyMetadataDirectory(in, out, gps, 1, &newGPS, ancestors, 0)) ||
        !TIFFSetSubDirectory(in, sourcePage) || !TIFFSetDirectory(out, page))
        return 0;
    if ((newExif && !TIFFSetField(out, TIFFTAG_EXIFIFD, newExif)) ||
        (newGPS && !TIFFSetField(out, TIFFTAG_GPSIFD, newGPS)))
        return 0;
    /* Rewrite only the IFD. The JPEG strips and tables remain in place. */
    return TIFFRewriteDirectory(out);
}
