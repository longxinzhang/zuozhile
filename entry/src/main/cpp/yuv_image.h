#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace posture {
struct Plane {
    const uint8_t* data = nullptr;
    int32_t length = 0;
    int32_t row = 0;
    int32_t pixel = 0;
};

struct RgbaImage {
    int32_t width;
    int32_t height;
    std::vector<uint8_t> bytes;
};

inline uint8_t Byte(int value) { return static_cast<uint8_t>(std::clamp(value, 0, 255)); }

inline RgbaImage ConvertYuv420(int width, int height, const std::array<Plane, 3>& planes) {
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        throw std::runtime_error("Invalid AR image dimensions");
    for (int i = 0; i < 3; ++i) {
        const auto& p = planes[i];
        int rows = i == 0 ? height : (height + 1) / 2;
        int cols = i == 0 ? width : (width + 1) / 2;
        int64_t last = int64_t(rows - 1) * p.row + int64_t(cols - 1) * p.pixel;
        if (!p.data || p.row <= 0 || p.pixel <= 0 || last >= p.length)
            throw std::runtime_error("Invalid AR plane bounds");
    }
    const double scale = std::min(1.0, 720.0 / std::max(width, height));
    RgbaImage out{std::max(1, int(width * scale)), std::max(1, int(height * scale)), {}};
    out.bytes.resize(out.width * out.height * 4);
    // The SDK supplies Y, U and V planes; U/V may share an interleaved buffer.
    for (int y = 0; y < out.height; ++y) {
        int sy = std::min(height - 1, int(y / scale));
        for (int x = 0; x < out.width; ++x) {
            int sx = std::min(width - 1, int(x / scale));
            int luma = planes[0].data[sy * planes[0].row + sx * planes[0].pixel];
            int u = planes[1].data[(sy / 2) * planes[1].row + (sx / 2) * planes[1].pixel] - 128;
            int v = planes[2].data[(sy / 2) * planes[2].row + (sx / 2) * planes[2].pixel] - 128;
            int c = std::max(0, luma - 16);
            size_t offset = (y * out.width + x) * 4;
            out.bytes[offset] = Byte((298 * c + 409 * v + 128) >> 8);
            out.bytes[offset + 1] = Byte((298 * c - 100 * u - 208 * v + 128) >> 8);
            out.bytes[offset + 2] = Byte((298 * c + 516 * u + 128) >> 8);
            out.bytes[offset + 3] = 255;
        }
    }
    return out;
}
}
