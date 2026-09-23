#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace posture {
// Use the SDK's semantic lip surfaces, not undocumented landmark indexes.
template <typename Label>
inline float LipGap(const float* vertices, int vertexFloatCount, const int32_t* indices,
    int indexCount, const Label* labels, int labelCount, int lowerLabel, int upperLabel) {
    if (!vertices || !indices || !labels || vertexFloatCount <= 0 || vertexFloatCount > 30000 ||
        vertexFloatCount % 3 || indexCount <= 0 || indexCount > 90000 || indexCount % 3 ||
        labelCount != indexCount / 3) return -1;
    std::vector<bool> upper(vertexFloatCount / 3), lower(vertexFloatCount / 3);
    float minX = std::numeric_limits<float>::infinity(), maxX = -minX;
    for (int t = 0; t < labelCount; ++t) {
        if (labels[t] != upperLabel && labels[t] != lowerLabel) continue;
        for (int k = 0; k < 3; ++k) {
            int index = indices[t * 3 + k];
            if (index < 0 || index >= vertexFloatCount / 3) return -1;
            const float* p = vertices + index * 3;
            if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || !std::isfinite(p[2])) return -1;
            (labels[t] == upperLabel ? upper : lower)[index] = true;
            minX = std::min(minX, p[0]);
            maxX = std::max(maxX, p[0]);
        }
    }
    const float width = maxX - minX;
    if (!std::isfinite(width) || width <= 1e-6) return -1;
    const float center = (minX + maxX) / 2;
    float gap = std::numeric_limits<float>::infinity();
    for (int u = 0; u < vertexFloatCount / 3; ++u) {
        if (!upper[u] || lower[u] || std::abs(vertices[u * 3] - center) > width * .2f) continue;
        for (int l = 0; l < vertexFloatCount / 3; ++l) {
            if (!lower[l] || upper[l] || std::abs(vertices[l * 3] - center) > width * .2f) continue;
            float x = vertices[u * 3] - vertices[l * 3];
            float y = vertices[u * 3 + 1] - vertices[l * 3 + 1];
            float z = vertices[u * 3 + 2] - vertices[l * 3 + 2];
            gap = std::min(gap, std::sqrt(x * x + y * y + z * z));
        }
    }
    const float ratio = gap / width;
    return std::isfinite(ratio) && ratio >= 0 && ratio <= 1 ? ratio : -1;
}
}
