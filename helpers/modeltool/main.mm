#import <Foundation/Foundation.h>
#import <ModelIO/ModelIO.h>
#import <SceneKit/SceneKit.h>
#import <SceneKit/ModelIO.h>
#import <ImageIO/ImageIO.h>
#include <assimp/Importer.hpp>
#include <assimp/Exporter.hpp>
#include <assimp/IOSystem.hpp>
#include <assimp/IOStream.hpp>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sandbox.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
using Failure = std::runtime_error;
constexpr size_t fileLimit = 128 * 1024 * 1024;
constexpr size_t resourceLimit = 512 * 1024 * 1024;

static bool within(const fs::path &path, const fs::path &root) {
    auto p = path.begin(), r = root.begin();
    for (; r != root.end(); ++r, ++p) if (p == path.end() || *p != *r) return false;
    return true;
}

class ReadStream final : public Assimp::IOStream {
    FILE *file;
    size_t length;
public:
    explicit ReadStream(const fs::path &path) {
        int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat info;
        if (fd < 0) throw Failure("A model resource could not be opened: " + path.filename().string());
        if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 || info.st_size > fileLimit) {
            close(fd);
            throw Failure("A model resource is not a regular file within the 128 MiB limit.");
        }
        length = size_t(info.st_size);
        file = fdopen(fd, "rb");
        if (!file) { close(fd); throw Failure("A model resource stream could not be opened."); }
    }
    ~ReadStream() override { fclose(file); }
    size_t Read(void *buffer, size_t size, size_t count) override { return fread(buffer, size, count, file); }
    size_t Write(const void *, size_t, size_t) override { return 0; }
    aiReturn Seek(size_t offset, aiOrigin origin) override {
        if (offset > length) return aiReturn_FAILURE;
        int mode = origin == aiOrigin_SET ? SEEK_SET : origin == aiOrigin_CUR ? SEEK_CUR : SEEK_END;
        off_t delta = origin == aiOrigin_END ? -off_t(offset) : off_t(offset);
        return fseeko(file, delta, mode) == 0 ? aiReturn_SUCCESS : aiReturn_FAILURE;
    }
    size_t Tell() const override { return size_t(ftello(file)); }
    size_t FileSize() const override { return length; }
    void Flush() override {}
};

class ResourceIO final : public Assimp::IOSystem {
    fs::path input, root;
    std::set<fs::path> opened;
    size_t total = 0;
public:
    ResourceIO(const fs::path &input, const fs::path &root) : input(fs::canonical(input)), root(fs::canonical(root)) {}
    fs::path resolve(const char *value) const {
        std::string text(value);
        if (text.size() > 4096 || text.find("://") != std::string::npos) return {};
        std::replace(text.begin(), text.end(), '\\', '/');
        fs::path path = fs::path(text).lexically_normal();
        if (path == input) return input;
        // Importers resolve companion files beside the snapshot. Map those back to the source folder.
        if (path.is_absolute() && within(path, input.parent_path()))
            path = root / path.lexically_relative(input.parent_path());
        else if (path.is_relative()) path = root / path;
        std::error_code error;
        path = fs::canonical(path, error);
        return !error && within(path, root) && fs::is_regular_file(path) ? path : fs::path();
    }
    bool Exists(const char *value) const override { return !resolve(value).empty(); }
    char getOsSeparator() const override { return '/'; }
    Assimp::IOStream *Open(const char *value, const char *mode = "rb") override {
        if (std::string(mode).find_first_of("wa+") != std::string::npos) return nullptr;
        auto path = resolve(value);
        if (path.empty()) throw Failure("A model resource is missing or is outside the source folder: " + fs::path(value).filename().string());
        auto stream = std::make_unique<ReadStream>(path);
        if (opened.insert(path).second) {
            if (opened.size() > 2048 || stream->FileSize() > resourceLimit - total)
                throw Failure("Model resources exceed 2048 files or 512 MiB.");
            total += stream->FileSize();
        }
        return stream.release();
    }
    void Close(Assimp::IOStream *stream) override { delete stream; }
};

using MeshPoint = std::array<float, 3>;
using Triangle = std::array<MeshPoint, 3>;
static std::vector<Triangle> geometry(const aiScene *scene) {
    if (!scene || !scene->mRootNode || !scene->mNumMeshes || scene->mNumMeshes > 100000 ||
        scene->mNumMaterials > 10000 || scene->mNumTextures > 2048)
        throw Failure("The model is empty or exceeds the scene size limit.");
    std::vector<Triangle> triangles;
    struct Node { const aiNode *node; aiMatrix4x4 parent; unsigned depth; };
    std::vector<Node> pending{{scene->mRootNode, aiMatrix4x4(), 0}};
    size_t nodes = 0;
    while (!pending.empty()) {
        auto item = pending.back(); pending.pop_back();
        if (++nodes > 100000 || item.depth > 256) throw Failure("The model node tree exceeds its limit.");
        auto transform = item.parent * item.node->mTransformation;
        for (unsigned m = 0; m < item.node->mNumMeshes; ++m) {
            if (item.node->mMeshes[m] >= scene->mNumMeshes) throw Failure("Invalid model mesh index.");
            auto mesh = scene->mMeshes[item.node->mMeshes[m]];
            if (mesh->mNumVertices > 3000000 || mesh->mNumFaces > 1000000 - triangles.size())
                throw Failure("The model exceeds one million triangles.");
            for (unsigned f = 0; f < mesh->mNumFaces; ++f) {
                const auto &face = mesh->mFaces[f];
                if (face.mNumIndices != 3) throw Failure("The model contains points or lines instead of a triangle surface.");
                Triangle triangle;
                for (unsigned v = 0; v < 3; ++v) {
                    if (face.mIndices[v] >= mesh->mNumVertices) throw Failure("Invalid model vertex index.");
                    auto p = transform * mesh->mVertices[face.mIndices[v]];
                    if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z))
                        throw Failure("The model contains a non-finite position.");
                    triangle[v] = {p.x, p.y, p.z};
                }
                triangles.push_back(triangle);
            }
        }
        if (item.node->mNumChildren > 100000 - pending.size()) throw Failure("Too many model nodes.");
        for (unsigned c = 0; c < item.node->mNumChildren; ++c)
            pending.push_back({item.node->mChildren[c], transform, item.depth + 1});
    }
    if (triangles.empty()) throw Failure("The model has no triangle surface.");
    return triangles;
}

static void compare(const std::vector<Triangle> &before, const std::vector<Triangle> &after) {
    if (before.size() != after.size()) throw Failure("The writer changed the model's triangle count.");
    float scale = 1;
    for (const auto &t : before) for (const auto &p : t) for (float c : p) scale = std::max(scale, std::abs(c));
    double tolerance = double(scale) * 0.00002;
    using Cell = std::array<int64_t, 3>;
    auto cell = [tolerance](const Triangle &t) -> Cell {
        Cell result;
        for (unsigned c = 0; c < 3; ++c)
            result[c] = int64_t(std::floor((double(t[0][c]) + t[1][c] + t[2][c]) / (3 * tolerance)));
        return result;
    };
    std::map<Cell, std::vector<const Triangle *>> remaining;
    for (const auto &t : before) remaining[cell(t)].push_back(&t);
    for (const auto &t : after) {
        auto center = cell(t);
        bool matched = false;
        for (int x = -1; x <= 1 && !matched; ++x) for (int y = -1; y <= 1 && !matched; ++y) for (int z = -1; z <= 1 && !matched; ++z) {
            auto found = remaining.find({center[0] + x, center[1] + y, center[2] + z});
            if (found == remaining.end()) continue;
            auto &candidates = found->second;
            for (size_t i = 0; i < candidates.size() && !matched; ++i) for (unsigned start = 0; start < 3 && !matched; ++start) {
                bool equal = true;
                for (unsigned p = 0; p < 3; ++p) for (unsigned c = 0; c < 3; ++c)
                    equal &= std::abs(double((*candidates[i])[(p + start) % 3][c]) - t[p][c]) <= tolerance;
                if (equal) { candidates[i] = candidates.back(); candidates.pop_back(); matched = true; }
            }
        }
        if (!matched) throw Failure("The writer changed the model's surface, winding, or transforms.");
    }
}

static const aiScene *read(Assimp::Importer &reader, const fs::path &input, const fs::path &resources) {
    reader.SetIOHandler(new ResourceIO(input, resources));
    auto scene = reader.ReadFile(input.string(), aiProcess_Triangulate | aiProcess_ValidateDataStructure);
    if (!scene) throw Failure(std::string("The model could not be read: ") + reader.GetErrorString());
    return scene;
}

static std::vector<unsigned char> textureBytes(const aiTexture &texture) {
    if (!texture.mWidth || texture.mWidth > fileLimit ||
        (texture.mHeight && uint64_t(texture.mWidth) * texture.mHeight > 32000000))
        throw Failure("A texture exceeds its size limit.");
    if (!texture.mHeight) {
        auto bytes = reinterpret_cast<const unsigned char *>(texture.pcData);
        return {bytes, bytes + texture.mWidth};
    }
    auto data = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(texture.pcData),
                             size_t(texture.mWidth) * texture.mHeight * 4);
    auto provider = CGDataProviderCreateWithCFData(data);
    auto space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto image = CGImageCreate(texture.mWidth, texture.mHeight, 8, 32, texture.mWidth * 4, space,
        CGBitmapInfo(kCGImageAlphaFirst | kCGBitmapByteOrder32Little), provider, nullptr, false, kCGRenderingIntentDefault);
    auto encoded = CFDataCreateMutable(kCFAllocatorDefault, 0);
    auto writer = CGImageDestinationCreateWithData(encoded, CFSTR("public.png"), 1, nullptr);
    bool okay = image && writer;
    if (okay) { CGImageDestinationAddImage(writer, image, nullptr); okay = CGImageDestinationFinalize(writer); }
    std::vector<unsigned char> bytes;
    if (okay) bytes.assign(CFDataGetBytePtr(encoded), CFDataGetBytePtr(encoded) + CFDataGetLength(encoded));
    if (writer) CFRelease(writer);
    CFRelease(encoded);
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider); CFRelease(data);
    if (!okay) throw Failure("A raw model texture could not be encoded.");
    return bytes;
}

static void prepareTextures(Assimp::Importer &reader, const fs::path &output, const std::string &assets, bool embed) {
    auto scene = reader.ApplyPostProcessing(aiProcess_EmbedTextures);
    if (!scene) throw Failure("The model textures could not be loaded.");
    if (scene->mNumTextures > 2048) throw Failure("The model has more than 2048 textures.");
    // FBX can address embedded images by filename. Use stable indices before renaming them.
    for (unsigned m = 0; m < scene->mNumMaterials; ++m) for (unsigned type = 1; type <= AI_TEXTURE_TYPE_MAX; ++type) {
        auto material = scene->mMaterials[m];
        for (unsigned slot = 0; slot < material->GetTextureCount(aiTextureType(type)); ++slot) {
            aiString path;
            material->GetTexture(aiTextureType(type), slot, &path);
            auto texture = scene->GetEmbeddedTexture(path.C_Str());
            if (!texture) throw Failure("A model texture is missing or is outside the source folder: " + std::string(path.C_Str()));
            for (unsigned i = 0; i < scene->mNumTextures; ++i) if (scene->mTextures[i] == texture) {
                aiString index("*" + std::to_string(i));
                material->AddProperty(&index, AI_MATKEY_TEXTURE(aiTextureType(type), slot));
                break;
            }
        }
    }
    size_t total = 0;
    std::map<const aiTexture *, std::string> names;
    for (unsigned m = 0; m < scene->mNumMaterials; ++m) {
        auto material = scene->mMaterials[m];
        for (unsigned type = 1; type <= AI_TEXTURE_TYPE_MAX; ++type) {
            for (unsigned slot = 0; slot < material->GetTextureCount(aiTextureType(type)); ++slot) {
                aiString path;
                material->GetTexture(aiTextureType(type), slot, &path);
                auto texture = scene->GetEmbeddedTexture(path.C_Str());
                if (!texture) throw Failure("A model texture is missing or is outside the source folder: " + std::string(path.C_Str()));
                if (!names.count(texture)) {
                    auto bytes = textureBytes(*texture);
                    if (bytes.size() > resourceLimit - total) throw Failure("Model textures exceed 512 MiB.");
                    total += bytes.size();
                    auto data = CFDataCreate(kCFAllocatorDefault, bytes.data(), bytes.size());
                    auto image = CGImageSourceCreateWithData(data, nullptr);
                    CFRelease(data);
                    if (!image || CGImageSourceGetCount(image) != 1) {
                        if (image) CFRelease(image);
                        throw Failure("A model texture is not a supported single image.");
                    }
                    auto properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(image, 0, nullptr);
                    auto width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
                    auto height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
                    auto kind = CGImageSourceGetType(image);
                    std::string extension = CFEqual(kind, CFSTR("public.jpeg")) ? "jpg" : "png";
                    bool unchanged = CFEqual(kind, CFSTR("public.jpeg")) || CFEqual(kind, CFSTR("public.png"));
                    if (!width || !height || width > 32000000 / height) { CFRelease(image); throw Failure("A texture exceeds 32 million pixels."); }
                    if (!unchanged) {
                        auto pixels = CGImageSourceCreateImageAtIndex(image, 0, nullptr);
                        auto encoded = CFDataCreateMutable(kCFAllocatorDefault, 0);
                        auto writer = CGImageDestinationCreateWithData(encoded, CFSTR("public.png"), 1, nullptr);
                        bool okay = pixels && writer;
                        if (okay) { CGImageDestinationAddImage(writer, pixels, nullptr); okay = CGImageDestinationFinalize(writer); }
                        if (okay) bytes.assign(CFDataGetBytePtr(encoded), CFDataGetBytePtr(encoded) + CFDataGetLength(encoded));
                        if (writer) CFRelease(writer); if (pixels) CGImageRelease(pixels); CFRelease(encoded);
                        if (!okay) { CFRelease(image); throw Failure("A texture could not be converted to PNG."); }
                    }
                    CFRelease(image);
                    std::string name = "texture-" + std::to_string(names.size()) + "." + extension;
                    auto writable = const_cast<aiTexture *>(texture);
                    delete[] writable->pcData;
                    writable->pcData = new aiTexel[(bytes.size() + sizeof(aiTexel) - 1) / sizeof(aiTexel)]{};
                    memcpy(writable->pcData, bytes.data(), bytes.size());
                    writable->mWidth = unsigned(bytes.size()); writable->mHeight = 0;
                    strncpy(writable->achFormatHint, extension.c_str(), sizeof(writable->achFormatHint) - 1);
                    writable->mFilename.Set(name);
                    names[texture] = assets + "/" + name;
                    if (!embed) {
                        fs::create_directory(output.parent_path() / assets);
                        std::ofstream file(output.parent_path() / names[texture], std::ios::binary);
                        file.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
                        file.close();
                        if (!file) throw Failure("A texture file could not be saved.");
                    }
                }
                if (!embed) {
                    aiString relative(names.at(texture));
                    material->AddProperty(&relative, AI_MATKEY_TEXTURE(aiTextureType(type), slot));
                }
            }
        }
    }
    if (!embed) {
        // Exporters must use the relative paths above, including when the source used embedded textures.
        auto writable = const_cast<aiScene *>(scene);
        for (unsigned i = 0; i < writable->mNumTextures; ++i) delete writable->mTextures[i];
        delete[] writable->mTextures; writable->mTextures = nullptr; writable->mNumTextures = 0;
    }
}

static void convertMesh(const fs::path &input, const fs::path &output, const fs::path &resources,
                        const std::string &format, const std::string &assets, bool embed) {
    Assimp::Importer reader;
    auto scene = read(reader, input, resources);
    auto before = geometry(scene);
    if (format == "fbx" || format == "glb2" || format == "obj" || format == "ply" || format == "plyb") {
        prepareTextures(reader, output, assets, embed && format != "ply" && format != "plyb");
        scene = reader.GetScene();
    }
    if (format == "fbx") {
        // The FBX writer omits the root node. Keep its transform and meshes on a child.
        auto writable = const_cast<aiScene *>(scene);
        auto root = new aiNode("ExportRoot");
        root->mNumChildren = 1;
        root->mChildren = new aiNode *[1]{writable->mRootNode};
        writable->mRootNode->mParent = root;
        writable->mRootNode = root;
    }
    Assimp::Exporter writer;
    if (writer.Export(scene, format, output.string()) != aiReturn_SUCCESS)
        throw Failure(std::string("The model could not be written: ") + writer.GetErrorString());
    Assimp::Importer verification;
    compare(before, geometry(read(verification, output, output.parent_path())));
}

static NSURL *url(const fs::path &path) { return [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]]; }

static MDLAsset *nativeRead(const fs::path &input) {
    MDLAsset *asset = [[MDLAsset alloc] initWithURL:url(input)];
    if (![asset childObjectsOfClass:MDLMesh.class].count) throw Failure("The native reader found no model meshes.");
    return asset;
}

static void nativeExport(MDLAsset *asset, const fs::path &output) {
    NSError *error = nil;
    if (![asset exportAssetToURL:url(output) error:&error])
        throw Failure(error.localizedDescription.UTF8String ?: "The native model writer failed.");
}

static std::string quoted(const fs::path &path) {
    std::string result = "\"";
    for (char c : path.string()) {
        if (c == '\\' || c == '"') result += '\\';
        if (static_cast<unsigned char>(c) < 32) throw Failure("A model path contains a control character.");
        result += c;
    }
    return result + '"';
}

static fs::path restrictProcess(const fs::path &input, const fs::path &resources, const fs::path &output,
                               const fs::path &temporary) {
    char systemTemp[PATH_MAX], executable[PATH_MAX];
    uint32_t executableSize = sizeof(executable);
    if (!confstr(_CS_DARWIN_USER_TEMP_DIR, systemTemp, sizeof(systemTemp)) ||
        _NSGetExecutablePath(executable, &executableSize) != 0)
        throw Failure("The model helper could not locate its system folders.");
    auto nativeTemp = fs::weakly_canonical(fs::path(systemTemp) / "TemporaryItems");
    auto nativeLayer = fs::weakly_canonical(systemTemp) / temporary.filename().replace_extension("usdc");
    auto program = fs::canonical(executable);
    std::string profile = "(version 1)(allow default)(deny network*)(deny file-read-data)"
        "(allow file-read-data (subpath \"/System/Library\")"
        " (subpath \"/System/Volumes/Preboot/Cryptexes/OS\") (subpath \"/System/Cryptexes/OS\")"
        " (subpath \"/usr/lib\") (subpath \"/usr/share\")"
        "(subpath \"/private/var/db/timezone\") (literal " + quoted(program) + ") (literal " + quoted(program.parent_path()) + ")"
        "(subpath " + quoted(nativeTemp) + ")"
        "(literal " + quoted(nativeLayer) + ")"
        "(literal \"/dev/urandom\") (literal \"/dev/null\") (literal " + quoted(input) + ")"
        "(subpath " + quoted(resources) + ") (subpath " + quoted(output.parent_path()) + "))"
        "(deny file-write*)(allow file-write* (subpath " + quoted(output.parent_path()) + ")"
        "(literal " + quoted(nativeLayer) + ")"
        "(subpath " + quoted(nativeTemp) + ") (literal \"/dev/null\"))";
    char *error = nullptr;
    if (sandbox_init(profile.c_str(), 0, &error) != 0) {
        std::string detail = error ?: "unknown error";
        sandbox_free_error(error);
        throw Failure("The model helper could not restrict file access: " + detail);
    }
    rlimit cpu{120, 120}, file{resourceLimit, resourceLimit};
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_FSIZE, &file)) throw Failure("Model process limits could not be set.");
    return nativeLayer;
}

static void moveExclusive(const fs::path &source, const fs::path &target) {
    if (renameatx_np(AT_FDCWD, source.c_str(), AT_FDCWD, target.c_str(), RENAME_EXCL) != 0)
        throw Failure("The output name is already used or cannot be saved.");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        fs::path work, publishedAssets, nativeLayer;
        try {
            if (argc != 10) throw Failure("Usage: modeltool INPUT OUTPUT FROM TO RESOURCES BINARY_PLY BINARY_STL EMBED_TEXTURES ASSET_FOLDER");
            if (fs::is_symlink(argv[1])) throw Failure("The model input must not be a symbolic link.");
            auto input = fs::canonical(argv[1]);
            auto output = fs::canonical(fs::path(argv[2]).parent_path()) / fs::path(argv[2]).filename();
            auto resources = fs::canonical(argv[5]);
            std::string from = argv[3], to = argv[4], assets = argv[9];
            std::map<std::string, std::set<std::string>> routes{
                {"3ds", {"fbx", "glb", "ply", "stl"}}, {"dae", {"fbx", "glb", "ply", "stl"}},
                {"fbx", {"glb", "ply", "stl"}}, {"glb", {"fbx", "ply", "stl"}},
                {"gltf", {"fbx", "glb", "ply", "stl"}}, {"obj", {"fbx", "glb", "ply", "stl", "usdz"}},
                {"ply", {"fbx", "glb", "stl", "usdz"}}, {"stl", {"fbx", "glb", "ply", "usdz"}},
                {"usda", {"ply", "stl", "usdz"}}, {"usdc", {"ply", "stl", "usdz"}}, {"usdz", {"ply", "stl"}}};
            if (!routes[from].count(to)) throw Failure("These model formats have no direct conversion route.");
            for (int i = 6; i <= 8; ++i) if (std::string(argv[i]) != "true" && std::string(argv[i]) != "false")
                throw Failure("A model option is invalid.");
            if (assets.empty() || assets.size() > 200 || assets[0] == '.' || assets.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") != std::string::npos)
                throw Failure("The texture folder name is invalid.");
            if (fs::exists(output) || fs::is_symlink(output) || fs::exists(output.parent_path() / assets))
                throw Failure("The output or texture folder already exists.");
            ReadStream checked(input);
            work = output.parent_path() / (".model-" + std::string(NSUUID.UUID.UUIDString.UTF8String));
            if (!fs::create_directory(work)) throw Failure("The model work folder could not be created.");
            fs::permissions(work, fs::perms::owner_all);
            auto temporary = work / (work.filename().string().substr(1) + output.extension().string());
            if (setenv("TMPDIR", work.c_str(), 1) || chdir(work.c_str()))
                throw Failure("The model temporary folder could not be selected.");
            nativeLayer = restrictProcess(input, resources, output, temporary);
            bool native = from == "usda" || from == "usdc" || from == "usdz";
            auto meshInput = input;
            auto meshResources = resources;
            if (to == "usdz") {
                MDLAsset *asset;
                if (native) asset = nativeRead(input);
                else {
                    meshInput = work / "native.obj";
                    convertMesh(input, meshInput, resources, "obj", "native-textures", false);
                    asset = nativeRead(meshInput);
                }
                [asset loadTextures];
                SCNScene *scene = [SCNScene sceneWithMDLAsset:asset];
                if (![scene writeToURL:url(temporary) options:nil delegate:nil progressHandler:nil])
                    throw Failure("The USDZ writer failed.");
                auto before = work / "before.ply", after = work / "after.ply";
                nativeExport(asset, before);
                nativeExport(nativeRead(temporary), after);
                Assimp::Importer a, b;
                compare(geometry(read(a, before, work)), geometry(read(b, after, work)));
            } else {
                if (native) {
                    meshInput = work / "native.ply"; meshResources = work;
                    nativeExport(nativeRead(input), meshInput);
                }
                std::string format = to == "glb" ? "glb2" : to;
                if (to == "ply" && std::string(argv[6]) == "true") format = "plyb";
                if (to == "stl" && std::string(argv[7]) == "true") format = "stlb";
                convertMesh(meshInput, temporary, meshResources, format, assets, std::string(argv[8]) == "true");
            }
            if (!fs::is_regular_file(temporary) || !fs::file_size(temporary) || fs::file_size(temporary) > resourceLimit)
                throw Failure("The model writer produced an invalid file.");
            if (fs::exists(work / assets)) {
                moveExclusive(work / assets, output.parent_path() / assets);
                publishedAssets = output.parent_path() / assets;
            }
            moveExclusive(temporary, output);
            std::error_code ignored;
            fs::remove(nativeLayer, ignored);
            fs::remove_all(work, ignored);
            return 0;
        } catch (const std::exception &error) {
            if (!nativeLayer.empty()) { std::error_code ignored; fs::remove(nativeLayer, ignored); }
            if (!publishedAssets.empty()) { std::error_code ignored; fs::remove_all(publishedAssets, ignored); }
            if (!work.empty()) { std::error_code ignored; fs::remove_all(work, ignored); }
            fprintf(stderr, "%s\n", error.what());
            return 1;
        }
    }
}
