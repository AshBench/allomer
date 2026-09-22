/* Independent FBX inspection for the model check. Not part of the app. */
#include "ufbx.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    ufbx_load_opts options = {0};
    ufbx_error error;
    ufbx_scene *scene = ufbx_load_file(argv[1], &options, &error);
    if (!scene) { fprintf(stderr, "%s\n", error.description.data); return 1; }
    for (size_t n = 0; n < scene->nodes.count; n++) {
        ufbx_node *node = scene->nodes.data[n];
        ufbx_mesh *mesh = node->mesh;
        if (!mesh) continue;
        for (size_t i = 0; i < mesh->num_indices; i++) {
            ufbx_vec3 position = ufbx_get_vertex_vec3(&mesh->vertex_position, i);
            position = ufbx_transform_position(&node->geometry_to_world, position);
            printf("v %.9g %.9g %.9g\n", position.x, position.y, position.z);
            if (mesh->vertex_uv.exists) {
                ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, i);
                printf("uv %.9g %.9g\n", uv.x, uv.y);
            }
        }
    }
    for (size_t t = 0; t < scene->texture_files.count; t++) {
        ufbx_texture_file *texture = &scene->texture_files.data[t];
        if (texture->content.size) {
            printf("embedded ");
            for (size_t b = 0; b < texture->content.size; b++) printf("%02x", ((unsigned char *)texture->content.data)[b]);
            printf("\n");
        } else printf("external %s\n", texture->relative_filename.data);
    }
    printf("animations %zu\n", scene->anim_stacks.count);
    ufbx_free_scene(scene);
    return 0;
}
