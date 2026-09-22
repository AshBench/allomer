#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

#ifndef CONVERTER_BINARY_NAME
#error Define the bundled executable name when building the launcher.
#endif

static void fail(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }

// Sandbox paths are Scheme strings. Escape each byte that can end the string.
static void quoted(FILE *stream, const char *path) {
    fputc('"', stream);
    for (; *path; path++) {
        if (*path == '"' || *path == '\\') fputc('\\', stream);
        if ((unsigned char)*path < 32) fail("A converter path contains a control character.");
        fputc(*path, stream);
    }
    fputc('"', stream);
}

int main(int argc, char **argv) {
    if (argc < 4) fail("Expected an input file, work folder, and converter arguments.");
    char input[PATH_MAX], work[PATH_MAX], executable[PATH_MAX], tool[PATH_MAX];
    struct stat info;
    uint32_t size = sizeof(executable);
    if (lstat(argv[1], &info) || !S_ISREG(info.st_mode) || !realpath(argv[1], input)
        || !realpath(argv[2], work) || _NSGetExecutablePath(executable, &size)
        || !realpath(executable, tool)) fail("The converter paths are invalid.");
    char *name = strrchr(tool, '/');
    if (!name || (size_t)(name - tool) + 1 + sizeof(CONVERTER_BINARY_NAME) > sizeof(tool)) fail("The tool path is too long.");
    strcpy(name + 1, CONVERTER_BINARY_NAME);
    if (chdir(work)) fail("The converter work folder could not be opened.");
    char *profile = NULL;
    size_t length = 0;
    FILE *stream = open_memstream(&profile, &length);
    if (!stream) fail("The converter sandbox could not be created.");
    fputs("(version 1)(allow default)(deny network*)(deny process-fork)(deny process-exec)"
          "(allow process-exec (literal ", stream);
    quoted(stream, tool);
    fputs("))(deny file-read-data)(allow file-read-data (literal ", stream);
    quoted(stream, input);
    fputs(") (literal ", stream);
    quoted(stream, tool);
#ifdef NATIVE_FRAMEWORK_CACHES
    fputs(") (literal ", stream);
    *name = '\0';
    quoted(stream, tool);
    *name = '/';
#endif
    fputs(") (subpath ", stream);
    quoted(stream, work);
#ifdef NATIVE_MEDIA_LIBRARIES
    char mediaPath[PATH_MAX], media[PATH_MAX];
    if (snprintf(mediaPath, sizeof(mediaPath), "%.*s/../Frameworks/Media", (int)(name - tool), tool) >= sizeof(mediaPath)
        || !realpath(mediaPath, media) || stat(media, &info) || !S_ISDIR(info.st_mode))
        fail("The bundled media library folder is invalid.");
    fputs(") (subpath ", stream);
    quoted(stream, media);
#endif
#ifdef WEB_RESOURCE_DIRECTORY
    char resources[PATH_MAX];
    if (argc < 5 || !realpath(argv[3], resources) || stat(resources, &info) || !S_ISDIR(info.st_mode))
        fail("The SVG resource folder is invalid.");
    fputs(") (subpath ", stream);
    quoted(stream, resources);
#endif
    fputs(") (literal \"/\") (subpath \"/System/Library\")"
          " (subpath \"/System/Volumes/Preboot/Cryptexes/OS\") (subpath \"/System/Cryptexes/OS\")"
          " (subpath \"/usr/lib\") (subpath \"/usr/share\")"
          " (subpath \"/private/var/db/timezone\") (literal \"/dev/null\") (literal \"/dev/urandom\"))"
          "(deny file-write*)(allow file-write* (subpath ", stream);
    quoted(stream, work);
    fputs(") (literal \"/dev/null\"))", stream);
#ifdef NATIVE_FRAMEWORK_CACHES
    char cacheRoot[PATH_MAX], cache[PATH_MAX];
    size_t cacheLength = confstr(_CS_DARWIN_USER_CACHE_DIR, cacheRoot, sizeof(cacheRoot));
    if (!cacheLength || cacheLength > sizeof(cacheRoot) || !realpath(cacheRoot, cache)
        || strlcat(cache, "/com.apple.metal", sizeof(cache)) >= sizeof(cache))
        fail("The native graphics cache path is invalid.");
    fputs("(allow file-read-data file-write* (subpath ", stream);
    quoted(stream, cache);
    fputs("))", stream);

    // Vision can compile framework-owned models into a cache named after this helper.
    char cacheParentPath[PATH_MAX], cacheParent[PATH_MAX], converterCachePath[PATH_MAX], converterCache[PATH_MAX];
    struct passwd *account = getpwuid(getuid());
    if (!account || snprintf(cacheParentPath, sizeof(cacheParentPath), "%s/Library/Caches", account->pw_dir) >= sizeof(cacheParentPath)
        || !realpath(cacheParentPath, cacheParent)
        || snprintf(converterCachePath, sizeof(converterCachePath), "%s/%s", cacheParent, CONVERTER_BINARY_NAME) >= sizeof(converterCachePath)
        || (mkdir(converterCachePath, 0700) && errno != EEXIST)
        || lstat(converterCachePath, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid()
        || !realpath(converterCachePath, converterCache))
        fail("The native framework cache path is invalid.");
    fputs("(allow file-read-data file-write* (subpath ", stream);
    quoted(stream, converterCache);
    fputs("))", stream);
#endif
    if (fclose(stream)) fail("The converter sandbox could not be written.");
    char *error = NULL;
    if (sandbox_init(profile, 0, &error)) fail(error ? error : "The converter sandbox failed.");
    free(profile);
    struct rlimit cpu = {120, 120}, file = {512ULL * 1024 * 1024, 512ULL * 1024 * 1024};
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_FSIZE, &file)) fail("The converter limits could not be set.");
    char temporary[PATH_MAX + 16], alternateTemporary[PATH_MAX + 16];
    snprintf(temporary, sizeof(temporary), "TMPDIR=%s", work);
    snprintf(alternateTemporary, sizeof(alternateTemporary), "TMP=%s", work);
    char *environment[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", temporary, alternateTemporary, NULL};
    environ = environment;
    argv[2] = tool;
    execv(tool, argv + 2);
    fail("The bundled converter could not start.");
}
