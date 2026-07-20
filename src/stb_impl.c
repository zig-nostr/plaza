/* The image codecs Plaza compiles in: stb_image decodes what the platform
 * decoder cannot hand us at a usable size, and stb_image_resize2 downscales it
 * to fit the canvas image budget (the registry decodes at most 512x512, and
 * has no downscaler of its own). Both are single-header public-domain code.
 *
 * Only the formats a Nostr feed actually carries are enabled; every other
 * decoder is compiled out to keep the binary and the attack surface small.
 * WebP and HEIC are deliberately absent: the platform decoder handles those,
 * and it is tried first. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_GIF
#define STBI_MAX_DIMENSIONS 16384
#include "stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"
