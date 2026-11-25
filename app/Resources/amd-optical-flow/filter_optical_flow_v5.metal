// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
// Generated from AMD SDKv1.1.4; see SOURCE.md.
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

kernel void CS(texture2d<int> _34 [[texture(0)]], texture2d<int, access::write> _47 [[texture(1)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    int2 _177 = int2(int3(gl_GlobalInvocationID).xy);
    int _329;
    _329 = -1;
    spvUnsafeArray<int2, 9> _224;
    int _338;
    for (int _339 = 0; _329 < 2; _329++, _339 = _338)
    {
        _338 = _339;
        for (int _336 = -1; _336 < 2; )
        {
            _224[_338] = int2(_34.read(uint2((_177 + int2(_329, _336))), 0).xy);
            _338++;
            _336++;
            continue;
        }
    }
    int _330;
    uint _331;
    _331 = 4294967295u;
    _330 = 0;
    uint _305;
    for (; _330 < 9; _331 = _305, _330++)
    {
        uint _333;
        _333 = 0u;
        for (int _332 = 0; _332 < 9; )
        {
            int2 _279 = _224[_330] - _224[_332];
            int _281 = _279.x;
            int _287 = _279.y;
            _333 = uint(_281 * _281) + (uint(_287 * _287) + _333);
            _332++;
            continue;
        }
        _305 = min(((_333 << uint(4)) | uint(_330)), _331);
    }
    _47.write(_224[_331 & 15u].xyyy, uint2(_177));
}

