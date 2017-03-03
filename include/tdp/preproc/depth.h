/* Copyright (c) 2016, Julian Straub <jstraub@csail.mit.edu> Licensed
 * under the MIT license. See the license file LICENSE.
 */
#pragma once
#include <stdint.h>
#include <tdp/data/image.h>

namespace tdp {

void ConvertDepthGpu(const Image<uint16_t>& dRaw, 
    Image<float>& d, 
    float scale,
    float dMin, 
    float dMax
    );

void ConvertDepthGpu(const Image<uint16_t>& dRaw,
    Image<float>& d,
    Image<float>& scale,
    float aScaleVsDist, float bScaleVsDist,
    float dMin, 
    float dMax
    );

void ConvertDepthToInverseDepthGpu(const Image<uint16_t>& dRaw,
    Image<float>& rho,
    float scale,
    float dMin, 
    float dMax
    );

void ConvertDepthToInverseDepthGpu(const Image<float>& d,
    Image<float>& rho);

void ConvertDepth(const Image<uint16_t>& dRaw, 
    Image<float>& d, 
    float scale,
    float dMin, 
    float dMax
    );

}
