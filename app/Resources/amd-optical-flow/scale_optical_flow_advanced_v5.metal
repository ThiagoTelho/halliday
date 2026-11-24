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

// Implementation of signed integer mod accurate to SPIR-V specification
template<typename Tx, typename Ty>
inline Tx spvSMod(Tx x, Ty y)
{
    Tx remainder = x - y * (x / y);
    return select(Tx(remainder + y), remainder, remainder == 0 || (x >= 0) == (y >= 0));
}

struct _240
{
    int2 _m0;
    uint _m1;
    uint _m2;
    uint _m3;
    uint _m4;
    float2 _m5;
};

kernel void CS(constant _240& _242 [[buffer(0)]], texture2d<uint> _259 [[texture(0)]], texture2d<uint> _267 [[texture(1)]], texture2d<int> _276 [[texture(2)]], texture2d<int, access::write> _288 [[texture(3)]], texture2d<uint> _294 [[texture(4)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]], uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]])
{
    threadgroup spvUnsafeArray<spvUnsafeArray<spvUnsafeArray<int2, 4>, 4>, 4> _508;
    threadgroup spvUnsafeArray<spvUnsafeArray<spvUnsafeArray<uint, 4>, 4>, 4> _551;
    threadgroup spvUnsafeArray<spvUnsafeArray<spvUnsafeArray<uint, 4>, 4>, 4> _605;
    do
    {
        bool _1410;
        do
        {
            if (_242._m3 <= 5u)
            {
                _1410 = true;
                break;
            }
            else
            {
                _1410 = (_294.read(uint2(int2(1, 0))).x & 15u) != 0u;
                break;
            }
            break; // unreachable workaround
        } while(false);
        if (_1410)
        {
            _288.write(int2(0).xyyy, uint2(int3(gl_GlobalInvocationID).xy));
            break;
        }
        int2 _933 = int2(_276.read(uint2(int2((int(gl_GlobalInvocationID.x) / 2) + ((spvSMod(int(gl_LocalInvocationID.z), 2) - 1) + spvSMod(int(gl_GlobalInvocationID.x), 2)), (int(gl_GlobalInvocationID.y) / 2) + (((int(gl_LocalInvocationID.z) / 2) - 1) + spvSMod(int(gl_GlobalInvocationID.y), 2)))), 0).xy);
        _508[int(gl_LocalInvocationID.z)][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] = _933 * int2(2);
        for (int _1411 = int(gl_LocalInvocationID.z); _1411 < 4; _1411 += 4)
        {
            int _785 = int(gl_GlobalInvocationID.x) * 4;
            int _964 = _242._m0.x >> int(_242._m1);
            int _970 = _964 - 4;
            int2 _981 = int2(max(0, min(_970, _785)), max(0, min(((_242._m0.y >> int(_242._m1)) - 1), ((int(gl_GlobalInvocationID.y) * 4) + _1411))));
            uint _1076 = ((_259.read(uint2(_981), 0).x | (_259.read(uint2((_981 + int2(1, 0))), 0).x << uint(8))) | (_259.read(uint2((_981 + int2(2, 0))), 0).x << uint(16))) | (_259.read(uint2((_981 + int2(3, 0))), 0).x << uint(24));
            uint _1446;
            if (_785 < 0)
            {
                uint _1081 = _1076 & 255u;
                uint _1444;
                if (_785 <= (-1))
                {
                    _1444 = (_1076 << uint(8)) | _1081;
                }
                else
                {
                    _1444 = _1076;
                }
                uint _1445;
                if (_785 <= (-2))
                {
                    _1445 = (_1444 << uint(8)) | _1081;
                }
                else
                {
                    _1445 = _1444;
                }
                uint _1447;
                if (_785 <= (-3))
                {
                    _1447 = (_1445 << uint(8)) | _1081;
                }
                else
                {
                    _1447 = _1445;
                }
                _1446 = _1447;
            }
            else
            {
                uint _1448;
                if (_785 > _970)
                {
                    uint _1113 = _1076 & 4278190080u;
                    uint _1442;
                    if (_785 >= (_964 - 3))
                    {
                        _1442 = (_1076 >> uint(8)) | _1113;
                    }
                    else
                    {
                        _1442 = _1076;
                    }
                    uint _1443;
                    if (_785 >= (_964 - 2))
                    {
                        _1443 = (_1442 >> uint(8)) | _1113;
                    }
                    else
                    {
                        _1443 = _1442;
                    }
                    uint _1449;
                    if (_785 >= (_964 - 1))
                    {
                        _1449 = (_1443 >> uint(8)) | _1113;
                    }
                    else
                    {
                        _1449 = _1443;
                    }
                    _1448 = _1449;
                }
                else
                {
                    _1448 = _1076;
                }
                _1446 = _1448;
            }
            _551[_1411][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] = _1446;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint _1413;
        _1413 = 0u;
        uint _836;
        for (int _1412 = 0; _1412 < 4; _1413 = _836, _1412++)
        {
            int2 _823 = int2(int(gl_GlobalInvocationID.x) * 4, (int(gl_GlobalInvocationID.y) * 4) + _1412) + _933;
            int _1177 = _242._m0.x >> int(_242._m1);
            int _1183 = _1177 - 4;
            int _1185 = _823.x;
            int2 _1194 = int2(max(0, min(_1183, _1185)), max(0, min(((_242._m0.y >> int(_242._m1)) - 1), _823.y)));
            uint _1289 = ((_267.read(uint2(_1194), 0).x | (_267.read(uint2((_1194 + int2(1, 0))), 0).x << uint(8))) | (_267.read(uint2((_1194 + int2(2, 0))), 0).x << uint(16))) | (_267.read(uint2((_1194 + int2(3, 0))), 0).x << uint(24));
            uint _1422;
            if (_1185 < 0)
            {
                uint _1294 = _1289 & 255u;
                uint _1420;
                if (_1185 <= (-1))
                {
                    _1420 = (_1289 << uint(8)) | _1294;
                }
                else
                {
                    _1420 = _1289;
                }
                uint _1421;
                if (_1185 <= (-2))
                {
                    _1421 = (_1420 << uint(8)) | _1294;
                }
                else
                {
                    _1421 = _1420;
                }
                uint _1423;
                if (_1185 <= (-3))
                {
                    _1423 = (_1421 << uint(8)) | _1294;
                }
                else
                {
                    _1423 = _1421;
                }
                _1422 = _1423;
            }
            else
            {
                uint _1424;
                if (_1185 > _1183)
                {
                    uint _1326 = _1289 & 4278190080u;
                    uint _1418;
                    if (_1185 >= (_1177 - 3))
                    {
                        _1418 = (_1289 >> uint(8)) | _1326;
                    }
                    else
                    {
                        _1418 = _1289;
                    }
                    uint _1419;
                    if (_1185 >= (_1177 - 2))
                    {
                        _1419 = (_1418 >> uint(8)) | _1326;
                    }
                    else
                    {
                        _1419 = _1418;
                    }
                    uint _1425;
                    if (_1185 >= (_1177 - 1))
                    {
                        _1425 = (_1419 >> uint(8)) | _1326;
                    }
                    else
                    {
                        _1425 = _1419;
                    }
                    _1424 = _1425;
                }
                else
                {
                    _1424 = _1289;
                }
                _1422 = _1424;
            }
            _836 = _1413 + uint(((abs(int(_551[_1412][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] & 255u) - int(_1422 & 255u)) + abs(int((_551[_1412][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] >> uint(8)) & 255u) - int((_1422 >> uint(8)) & 255u))) + abs(int((_551[_1412][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] >> uint(16)) & 255u) - int((_1422 >> uint(16)) & 255u))) + abs(int((_551[_1412][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] >> uint(24)) & 255u) - int((_1422 >> uint(24)) & 255u)));
        }
        _605[int(gl_LocalInvocationID.z)][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] = _1413;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (int(gl_LocalInvocationID.z) == 0)
        {
            uint _1415;
            _1415 = 0u;
            uint _1459;
            uint _1460;
            int _1414 = 0;
            uint _1416 = 4294967295u;
            for (; _1414 < 4; _1416 = _1460, _1415 = _1459, _1414++)
            {
                if (_605[_1414][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)] < _1416)
                {
                    _1460 = _605[_1414][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)];
                    _1459 = uint(_1414);
                }
                else
                {
                    _1460 = _1416;
                    _1459 = _1415;
                }
            }
            _288.write(_508[_1415][int(gl_LocalInvocationID.y)][int(gl_LocalInvocationID.x)].xyyy, uint2(int3(gl_GlobalInvocationID).xy));
        }
        break;
    } while(false);
}

