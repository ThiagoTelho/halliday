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

// Implementation of signed integer mod accurate to SPIR-V specification
template<typename Tx, typename Ty>
inline Tx spvSMod(Tx x, Ty y)
{
    Tx remainder = x - y * (x / y);
    return select(Tx(remainder + y), remainder, remainder == 0 || (x >= 0) == (y >= 0));
}

struct _43
{
    int2 _m0;
    uint _m1;
    uint _m2;
    uint _m3;
    uint _m4;
    float2 _m5;
};

kernel void CS(constant _43& _45 [[buffer(0)]], texture2d<uint> _54 [[texture(0)]], texture2d<uint, access::read_write> _64 [[texture(1)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]], uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]])
{
    threadgroup spvUnsafeArray<uint, 2560> _128;
    uint _358 = uint(_45._m0.x) / 3u;
    uint _362 = uint(_45._m0.y) / 3u;
    uint _365 = uint(int(gl_GlobalInvocationID.z));
    uint _373 = _358 * (_365 % 3u);
    uint _376 = _362 * (_365 / 3u);
    uint _382 = _376 + _362;
    uint _385 = uint(int(gl_LocalInvocationIndex) * 10);
    for (int _549 = 0; _549 < 10; )
    {
        _128[_385 + uint(_549)] = 0u;
        _549++;
        continue;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint _405 = _373 + uint(4 * int(gl_GlobalInvocationID.x));
    if (_405 < (_373 + _358))
    {
        int2 _565;
        _565 = int2(int(_405), int(_376 + uint(int(gl_GlobalInvocationID.y))));
        for (; uint(_565.y) < _382; )
        {
            uint4 _443 = uint4(_54.read(uint2(_565), 0).x, _54.read(uint2((_565 + int2(1, 0))), 0).x, _54.read(uint2((_565 + int2(2, 0))), 0).x, _54.read(uint2((_565 + int2(3, 0))), 0).x) * uint4(10u);
            uint _446 = uint(spvSMod(int(gl_LocalInvocationIndex), 10));
            uint _452 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_128[_443.x + _446], 1u, memory_order_relaxed);
            uint _458 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_128[_443.y + _446], 1u, memory_order_relaxed);
            uint _464 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_128[_443.z + _446], 1u, memory_order_relaxed);
            uint _470 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_128[_443.w + _446], 1u, memory_order_relaxed);
            int2 _562 = _565;
            _562.y = _565.y + 128;
            _565 = _562;
            continue;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint _551;
    _551 = 0u;
    for (int _550 = 0; _550 < 10; )
    {
        _551 += _128[_385 + uint(_550)];
        _550++;
        continue;
    }
    uint _548 = _64.atomic_fetch_add(uint2(int2(int(uint(256 * int(gl_GlobalInvocationID.z)) + uint(int(gl_LocalInvocationIndex))), 0)), _551).x;
}

