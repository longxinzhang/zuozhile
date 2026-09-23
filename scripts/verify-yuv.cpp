#include "../entry/src/main/cpp/yuv_image.h"
#include <cassert>
#include <iostream>

int main() {
    using posture::Plane;
    using posture::ConvertYuv420;
    uint8_t y[] = {16, 235, 81, 81, 16, 235, 81, 81};
    uint8_t u[] = {128, 90}, v[] = {128, 240};
    std::array<Plane, 3> planar = {{{y, 8, 4, 1}, {u, 2, 2, 1}, {v, 2, 2, 1}}};
    auto expected = ConvertYuv420(4, 2, planar);
    assert(expected.bytes[0] == 0 && expected.bytes[3] == 255);
    assert(expected.bytes[4] == 255 && expected.bytes[5] == 255);
    assert(expected.bytes[8] >= 253 && expected.bytes[9] <= 1 && expected.bytes[10] <= 1);
    uint8_t paddedY[] = {16, 235, 81, 81, 9, 9, 16, 235, 81, 81, 9, 9};
    uint8_t uv[] = {128, 128, 90, 240};
    std::array<Plane, 3> interleaved = {{{paddedY, 12, 6, 1}, {uv, 4, 4, 2}, {uv + 1, 3, 4, 2}}};
    assert(ConvertYuv420(4, 2, interleaved).bytes == expected.bytes);
    auto rejects = [&](int width, int height, std::array<Plane, 3> planes) {
        bool failed = false;
        try { ConvertYuv420(width, height, planes); } catch (const std::runtime_error&) { failed = true; }
        assert(failed);
    };
    rejects(0, 2, planar);
    rejects(8193, 2, planar);
    auto bad = planar;
    bad[2].length = 1; rejects(4, 2, bad);
    bad = planar; bad[0].data = nullptr; rejects(4, 2, bad);
    bad = planar; bad[0].row = 0; rejects(4, 2, bad);
    bad = planar; bad[1].pixel = -1; rejects(4, 2, bad);
    uint8_t oddY[9] = {}, oddUV[4] = {128, 128, 128, 128};
    std::array<Plane, 3> odd = {{{oddY, 9, 3, 1}, {oddUV, 4, 2, 1}, {oddUV, 4, 2, 1}}};
    assert(ConvertYuv420(3, 3, odd).bytes.size() == 36);
    std::vector<uint8_t> largeY(1440 * 1080, 235), largeUV(720 * 540, 128);
    std::array<Plane, 3> large = {{{largeY.data(), int(largeY.size()), 1440, 1},
        {largeUV.data(), int(largeUV.size()), 720, 1}, {largeUV.data(), int(largeUV.size()), 720, 1}}};
    auto resized = ConvertYuv420(1440, 1080, large);
    assert(resized.width == 720 && resized.height == 540);
    for (auto byte : resized.bytes) assert(byte == 255);
    std::cout << "PASS: YUV planar/interleaved/padded/odd dimensions, RGB channels, resizing and bounds\n";
}
