#import <AppKit/AppKit.h>

// The caller owns the returned buffers and releases them with free().
int render_rtf(const unsigned char *input, size_t length,
               unsigned char **html, size_t *htmlLength,
               unsigned char **text, size_t *textLength) {
    *html = NULL;
    *text = NULL;
    @autoreleasepool {
        @try {
            NSData *data = [NSData dataWithBytesNoCopy:(void *)input length:length freeWhenDone:NO];
            NSAttributedString *body = [[NSAttributedString alloc] initWithRTF:data documentAttributes:nil];
            if (!body) return 1;
            NSData *plain = [body.string dataUsingEncoding:NSUTF8StringEncoding];
            NSData *rich = [body dataFromRange:NSMakeRange(0, body.length)
                documentAttributes:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                    NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)} error:nil];
            if (!plain || !rich || plain.length > 16 * 1024 * 1024 || rich.length > 32 * 1024 * 1024) return 1;
            *htmlLength = rich.length;
            *textLength = plain.length;
            *html = malloc(MAX(1, rich.length));
            *text = malloc(MAX(1, plain.length));
            if (!*html || !*text) { free(*html); free(*text); *html = NULL; *text = NULL; return 1; }
            memcpy(*html, rich.bytes, rich.length);
            memcpy(*text, plain.bytes, plain.length);
            return 0;
        } @catch (NSException *exception) {
            free(*html); free(*text); *html = NULL; *text = NULL;
            return 1;
        }
    }
}
