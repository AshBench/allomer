#include "mupdf/fitz.h"
#include "mupdf/pdf.h"
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>

static void add_text_layer(fz_context *ctx, pdf_document *document, pdf_document *overlay,
        pdf_graft_map *map, int index)
{
    pdf_obj *page = pdf_lookup_page_obj(ctx, document, index);
    pdf_obj *layer = pdf_lookup_page_obj(ctx, overlay, index);
    pdf_obj *layer_resources = pdf_dict_get_inheritable(ctx, layer, PDF_NAME(Resources));
    fz_rect box = pdf_dict_get_inheritable_rect(ctx, page, PDF_NAME(MediaBox));
    fz_rect layer_box = pdf_dict_get_inheritable_rect(ctx, layer, PDF_NAME(MediaBox));
    if (!isfinite(box.x0) || !isfinite(box.y0) || !isfinite(box.x1) || !isfinite(box.y1)
        || !isfinite(layer_box.x0) || !isfinite(layer_box.y0) || !isfinite(layer_box.x1) || !isfinite(layer_box.y1)
        || box.x1 <= box.x0 || box.y1 <= box.y0
        || fabsf(box.x0 - layer_box.x0) > 0.01f || fabsf(box.y0 - layer_box.y0) > 0.01f
        || fabsf(box.x1 - layer_box.x1) > 0.01f || fabsf(box.y1 - layer_box.y1) > 0.01f)
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "The PDF text layer has different page bounds.");
    if (!pdf_dict_len(ctx, pdf_dict_get(ctx, layer_resources, PDF_NAME(Font)))) return;

    pdf_obj *resources = NULL, *xobjects = NULL, *grafted = NULL, *form = NULL, *contents = NULL;
    fz_buffer *data = NULL, *commands = NULL;
    fz_stream *stream = NULL;
    fz_var(resources); fz_var(xobjects); fz_var(grafted); fz_var(form); fz_var(contents);
    fz_var(data); fz_var(commands); fz_var(stream);
    fz_try(ctx)
    {
        stream = pdf_open_contents_stream(ctx, overlay, pdf_dict_get(ctx, layer, PDF_NAME(Contents)));
        data = fz_new_buffer(ctx, 4096);
        unsigned char chunk[65536];
        size_t size;
        while ((size = fz_read(ctx, stream, chunk, sizeof(chunk))))
        {
            if (fz_buffer_storage(ctx, data, NULL) + size > 128 * 1024 * 1024)
                fz_throw(ctx, FZ_ERROR_LIMIT, "The PDF text layer is too large.");
            fz_append_data(ctx, data, chunk, size);
        }
        grafted = pdf_graft_mapped_object(ctx, map, layer_resources);
        form = pdf_new_xobject(ctx, document, box, fz_identity, grafted, data);
        pdf_obj *prior = pdf_dict_get_inheritable(ctx, page, PDF_NAME(Resources));
        resources = prior ? pdf_copy_dict(ctx, prior) : pdf_new_dict(ctx, document, 1);
        prior = pdf_dict_get(ctx, resources, PDF_NAME(XObject));
        xobjects = prior ? pdf_copy_dict(ctx, prior) : pdf_new_dict(ctx, document, 1);
        char name[40];
        int sequence = 0;
        do {
            if (sequence >= 100000) fz_throw(ctx, FZ_ERROR_LIMIT, "The PDF has too many resource names.");
            snprintf(name, sizeof(name), "OCR%d", sequence++);
        } while (pdf_dict_gets(ctx, xobjects, name));
        pdf_dict_puts(ctx, xobjects, name, form);
        pdf_dict_put(ctx, resources, PDF_NAME(XObject), xobjects);
        contents = pdf_new_array(ctx, document, 3);
        commands = fz_new_buffer(ctx, 64);
        fz_append_printf(ctx, commands, "q /%s Do Q\n", name);
        pdf_array_push_drop(ctx, contents, pdf_add_stream(ctx, document, commands, NULL, 0));
        prior = pdf_dict_get(ctx, page, PDF_NAME(Contents));
        if (pdf_is_array(ctx, prior)) {
            for (int i = 0; i < pdf_array_len(ctx, prior); ++i)
                pdf_array_push(ctx, contents, pdf_array_get(ctx, prior, i));
        } else if (prior) {
            pdf_array_push(ctx, contents, prior);
        }
        pdf_dict_put(ctx, page, PDF_NAME(Resources), resources);
        pdf_dict_put(ctx, page, PDF_NAME(Contents), contents);
    }
    fz_always(ctx)
    {
        fz_drop_stream(ctx, stream);
        fz_drop_buffer(ctx, data);
        fz_drop_buffer(ctx, commands);
        pdf_drop_obj(ctx, contents);
        pdf_drop_obj(ctx, form);
        pdf_drop_obj(ctx, grafted);
        pdf_drop_obj(ctx, xobjects);
        pdf_drop_obj(ctx, resources);
    }
    fz_catch(ctx) { fz_rethrow(ctx); }
}

int pdfoverlay_main(int argc, char **argv)
{
    if (argc != 4) { fputs("Expected: overlay BASE.pdf TEXT.pdf OUTPUT.pdf\n", stderr); return 1; }
    for (int i = 1; i <= 2; ++i) {
        struct stat info;
        if (stat(argv[i], &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 512LL * 1024 * 1024) {
            fputs("Each PDF input must be a regular file up to 512 MiB.\n", stderr); return 1;
        }
    }
    fz_context *ctx = fz_new_context(NULL, NULL, 64 * 1024 * 1024);
    if (!ctx) { fputs("The PDF context could not be created.\n", stderr); return 1; }
    pdf_document *document = NULL, *overlay = NULL;
    pdf_graft_map *map = NULL;
    int status = 0;
    fz_var(document); fz_var(overlay); fz_var(map); fz_var(status);
    fz_try(ctx)
    {
        document = pdf_open_document(ctx, argv[1]);
        overlay = pdf_open_document(ctx, argv[2]);
        if (pdf_dict_get(ctx, pdf_trailer(ctx, document), PDF_NAME(Encrypt))
            || pdf_dict_get(ctx, pdf_trailer(ctx, overlay), PDF_NAME(Encrypt)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Encrypted PDF input is not supported.");
        int count = pdf_count_pages(ctx, document);
        if (count < 1 || count > 10000 || count != pdf_count_pages(ctx, overlay))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "The PDF text layer has a different page count.");
        map = pdf_new_graft_map(ctx, document);
        for (int i = 0; i < count; ++i) add_text_layer(ctx, document, overlay, map, i);
        pdf_write_options options = pdf_default_write_options;
        options.do_compress = 1;
        options.do_preserve_metadata = 1;
        options.dont_regenerate_id = 1;
        pdf_save_document(ctx, document, argv[3], &options);
    }
    fz_always(ctx)
    {
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, overlay);
        pdf_drop_document(ctx, document);
    }
    fz_catch(ctx) { fprintf(stderr, "%s\n", fz_caught_message(ctx)); status = 1; }
    fz_drop_context(ctx);
    return status;
}
