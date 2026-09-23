#include "../entry/src/main/cpp/lip_gap.h"
#include <array>
#include <cassert>
#include <iostream>

int main() {
    std::array<float, 18> vertices = {-1, .1f, 0, 0, .1f, 0, 1, .1f, 0,
        -1, -.1f, 0, 0, -.1f, 0, 1, -.1f, 0};
    int32_t indices[] = {0, 1, 2, 3, 4, 5}, labels[] = {2, 1};
    auto gap = [&]() { return posture::LipGap(vertices.data(), 18, indices, 6, labels, 2, 1, 2); };
    assert(std::abs(gap() - .1f) < 1e-6);
    vertices[4] = vertices[13] = 0;
    assert(gap() == 0);
    vertices[4] = .03f;
    assert(std::abs(gap() - .015f) < 1e-6);
    for (auto& value : vertices) value *= 7;
    assert(std::abs(gap() - .015f) < 1e-6);
    for (int i = 0; i < 6; ++i) {
        vertices[i * 3] += 10;
        vertices[i * 3 + 1] -= 3;
        vertices[i * 3 + 2] += 4;
    }
    assert(std::abs(gap() - .015f) < 1e-6);
    assert(posture::LipGap(nullptr, 18, indices, 6, labels, 2, 1, 2) == -1);
    assert(posture::LipGap(vertices.data(), 18, indices, 6, labels, 1, 1, 2) == -1);
    indices[1] = 9000;
    assert(gap() == -1);
    indices[1] = 1;
    vertices[0] = std::numeric_limits<float>::quiet_NaN();
    assert(gap() == -1);
    float joined[] = {-1, 0, 0, 0, .1f, 0, 1, 0, 0, 0, -.1f, 0};
    int32_t seamIndices[] = {0, 1, 2, 0, 3, 2};
    assert(std::abs(posture::LipGap(joined, 12, seamIndices, 6, labels, 2, 1, 2) - .1f) < 1e-6);
    assert(posture::LipGap(joined, 12, seamIndices, 6, labels, 2, 9, 8) == -1);
    std::cout << "PASS: lip-surface gap, shared corners, closed lips, slight separation, scale/translation and invalid mesh\n";
}
