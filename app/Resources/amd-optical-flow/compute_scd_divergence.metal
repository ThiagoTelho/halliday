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
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>
#include <metal_atomic>

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

template <typename ImageT>
void spvImageFence(ImageT img) { img.fence(); }

kernel void CS(texture2d<uint, access::read_write> _119 [[texture(0)]], texture2d<float, access::read_write> _135 [[texture(1)]], texture2d<uint, access::read_write> _148 [[texture(2)]], texture2d<uint, access::read_write> _178 [[texture(3)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]], uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]])
{
    threadgroup spvUnsafeArray<float, 256> _202;
    threadgroup spvUnsafeArray<float, 256> _389;
    threadgroup spvUnsafeArray<float, 256> _421;
    threadgroup spvUnsafeArray<float2, 256> _554;
    int2 _1364 = int2(int(gl_GlobalInvocationID.x), 0);
    spvImageFence(_119);
    _202[int(gl_LocalInvocationIndex)] = float(_119.read(uint2(_1364)).x);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int _977 = int(gl_LocalInvocationIndex) + 1;
    int _986 = int(gl_LocalInvocationIndex) + 2;
    int _1004 = int(gl_LocalInvocationIndex) + 4;
    float _1020 = ((((((((((0.008812229149043560028076171875 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + (-5))))]) + (0.02714357711374759674072265625 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + (-4))))])) + (0.065114058554172515869140625 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + (-3))))])) + (0.12164907157421112060546875 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + (-2))))])) + (0.1769983470439910888671875 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + (-1))))])) + (0.20056541264057159423828125 * _202[max(0, min(255, int(gl_LocalInvocationIndex)))])) + (0.1769983470439910888671875 * _202[max(0, min(255, _977))])) + (0.12164907157421112060546875 * _202[max(0, min(255, _986))])) + (0.065114058554172515869140625 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + 3)))])) + (0.02714357711374759674072265625 * _202[max(0, min(255, _1004))])) + (0.008812229149043560028076171875 * _202[max(0, min(255, (int(gl_LocalInvocationIndex) + 5)))]);
    float _1022 = _1020 + 1.0;
    if (int(gl_GlobalInvocationID.y) == 0)
    {
        if (int(gl_LocalInvocationIndex) == 0)
        {
            _389[255] = 1.0;
        }
        else
        {
            _389[int(gl_LocalInvocationIndex) - 1] = _1022;
        }
    }
    else
    {
        if (int(gl_GlobalInvocationID.y) == 1)
        {
            _389[int(gl_LocalInvocationIndex)] = _1022;
        }
        else
        {
            if (int(gl_GlobalInvocationID.y) == 2)
            {
                if (int(gl_LocalInvocationIndex) == 255)
                {
                    _389[0] = 1.0;
                }
                else
                {
                    _389[_977] = _1022;
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    _421[int(gl_LocalInvocationIndex)] = _389[int(gl_LocalInvocationIndex)];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool _1069 = int(gl_LocalInvocationIndex) < 128;
    if (_1069)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[int(gl_LocalInvocationIndex) + 128];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool _1082 = int(gl_LocalInvocationIndex) < 64;
    if (_1082)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[int(gl_LocalInvocationIndex) + 64];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    bool _1095 = int(gl_LocalInvocationIndex) < 32;
    if (_1095)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[int(gl_LocalInvocationIndex) + 32];
    }
    bool _1108 = int(gl_LocalInvocationIndex) < 16;
    if (_1108)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[int(gl_LocalInvocationIndex) + 16];
    }
    bool _1121 = int(gl_LocalInvocationIndex) < 8;
    if (_1121)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[int(gl_LocalInvocationIndex) + 8];
    }
    bool _1134 = int(gl_LocalInvocationIndex) < 4;
    if (_1134)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[_1004];
    }
    bool _1147 = int(gl_LocalInvocationIndex) < 2;
    if (_1147)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[_986];
    }
    if (int(gl_LocalInvocationIndex) < 1)
    {
        _421[int(gl_LocalInvocationIndex)] += _421[_977];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    _389[int(gl_LocalInvocationIndex)] /= _421[0];
    float _1181 = _389[int(gl_LocalInvocationIndex)];
    spvImageFence(_135);
    float4 _1482 = _135.read(uint2(_1364));
    float _1483 = _1482.x;
    _554[int(gl_LocalInvocationIndex)] = float2(_1181 * log(_1181 / _1483), _1483 * log(_1483 / _1181));
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1069)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[int(gl_LocalInvocationIndex) + 128];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1082)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[int(gl_LocalInvocationIndex) + 64];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1095)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[int(gl_LocalInvocationIndex) + 32];
    }
    if (_1108)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[int(gl_LocalInvocationIndex) + 16];
    }
    if (_1121)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[int(gl_LocalInvocationIndex) + 8];
    }
    if (_1134)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[_1004];
    }
    if (_1147)
    {
        _554[int(gl_LocalInvocationIndex)] += _554[_986];
    }
    if (int(gl_LocalInvocationIndex) == 0)
    {
        float2 _1298 = _554[0] + _554[1];
        uint _1489 = _148.atomic_fetch_add(uint2(int2(int(gl_GlobalInvocationID.y), 0)), uint((1.0 - exp(-(abs(_1298.x) + abs(_1298.y)))) * 111111.109375)).x;
        uint _1497 = _178.atomic_fetch_add(uint2(int2(2, 0)), 1u).x;
        if (_1497 == 26u)
        {
            spvImageFence(_148);
            spvImageFence(_148);
            spvImageFence(_148);
            float _1330 = float(min(_148.read(uint2(int2(0))).x, min(_148.read(uint2(int2(1, 0))).x, _148.read(uint2(int2(2, 0))).x))) * 9.9999999747524270787835121154785e-07;
            spvImageFence(_178);
            uint _1332 = _178.read(uint2(int2(1, 0))).x << uint(1);
            uint _1581;
            if (_1330 > 0.449999988079071044921875)
            {
                _1581 = _1332 | 1u;
            }
            else
            {
                _1581 = _1332;
            }
            _178.write(uint4(as_type<uint>(_1330)), uint2(int2(0)));
            _178.write(uint4(_1581), uint2(int2(1, 0)));
            _178.write(uint4(0u), uint2(int2(2, 0)));
            _148.write(uint4(0u), uint2(int2(0)));
            _148.write(uint4(0u), uint2(int2(1, 0)));
            _148.write(uint4(0u), uint2(int2(2, 0)));
        }
    }
    if (int(gl_GlobalInvocationID.y) == 1)
    {
        _135.write(float4(_1181), uint2(_1364));
        _119.write(uint4(0u), uint2(_1364));
    }
}

