import Foundation
import Metal
import simd

@main struct OpenXRCompositionMetalTests {
    struct Uniforms {
        var projection: SIMD4<Float>
        var headPosition: SIMD4<Float>
        var rotation: simd_float4x4
        var flags: SIMD4<Float>
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("No Metal") }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        \(projectionColourShaderFunctions)
        \(openXRCompositionShaderFunctions)
        struct Out { float4 position [[position]]; float2 uv; };
        struct U { float4 projection; float4 headPosition; float4x4 rotation; float4 flags; };
        vertex Out vs(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p*2.0-1.0,0,1),float2(p.x,1.0-p.y)};
        }
        fragment float4 fs(Out in [[stage_in]], constant U &u [[buffer(0)]],
            constant OpenXRCompositionHeader &h [[buffer(3)]], constant OpenXRCompositionPlane *p [[buffer(4)]],
            array<texture2d<float>, OPENXR_MAX_PANELS> raw [[texture(55)]],
            array<texture2d<float>, OPENXR_MAX_PANELS> srgb [[texture(63)]], sampler smp [[sampler(0)]]) {
            uint eye = min(1u,uint(in.uv.x*2));
            float2 uv = float2(in.uv.x*2-eye,in.uv.y);
            float3 ray = (u.rotation*float4(normalize(float3(uv.x*2-1,1-uv.y*2,-1)),0)).xyz;
            return openxr_compose(u.headPosition.xyz,ray,eye,u.projection,u.flags.x>0.5,u.flags.y>0.5,h,p,raw,srgb,smp);
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        let sceneLibrary = try device.makeLibrary(source: shaderSource, options: nil)
        let sceneDescriptor = MTLRenderPipelineDescriptor()
        sceneDescriptor.vertexFunction = sceneLibrary.makeFunction(name: "fullscreen_vs")
        sceneDescriptor.fragmentFunction = sceneLibrary.makeFunction(name: "scene_fs")
        sceneDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        _ = try device.makeRenderPipelineState(descriptor: sceneDescriptor)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vs")
        descriptor.fragmentFunction = library.makeFunction(name: "fs")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: sd)!
        func texture(_ color: SIMD4<Float>, width: Int = 4, height: Int = 4) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            td.storageMode = .shared; td.usage = [.shaderRead]
            let texture = device.makeTexture(descriptor: td)!
            let pixels = [SIMD4<Float>](repeating: color, count: width*height)
            pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width*16) }
            return texture
        }
        let placeholder = texture(.zero)
        let blue = texture([0,0,1,1]), green = texture([0,1,0,1])
        let identity = simd_quatf(angle: 0, axis: [0,1,0])
        func panel(_ t: MTLTexture, mode: OpenXRComposition.AlphaMode = .opaque,
                   eye: OpenXRComposition.EyeVisibility = .both) -> OpenXRComposition.Panel {
            .init(texture: t, position: [0,0,-1], orientation: identity, size: [2,2],
                  eyeVisibility: eye, alphaMode: mode)
        }
        func render(_ composition: OpenXRComposition, projection: SIMD4<Float> = [1,0,0,1],
                    premultiplied: Bool = false, head: SIMD3<Float> = .zero,
                    rotation: simd_quatf? = nil) -> [SIMD4<Float>] {
            let q = rotation ?? identity
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 128, height: 64, mipmapped: false)
            td.storageMode = .shared; td.usage = [.renderTarget]
            let target = device.makeTexture(descriptor: td)!
            let cb = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(pipeline); enc.setFragmentSamplerState(sampler,index:0)
            var u = Uniforms(projection: projection, headPosition: SIMD4(head,1), rotation: simd_float4x4(q), flags: SIMD4(1,premultiplied ? 1:0,0,0))
            enc.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            var fixation = [SIMD4<Float>.zero, SIMD4<Float>.zero]
            enc.setFragmentBytes(&fixation, length: 32, index: 5)
            OpenXRComposition.bind(composition,to:enc,headPosition:head,headOrientation:q,placeholder:placeholder)
            enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted(); precondition(cb.status == .completed)
            var pixels = [SIMD4<Float>](repeating:.zero,count:128*64)
            pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:128*16,
                from:MTLRegionMake2D(0,0,128,64),mipmapLevel:0) }
            return pixels
        }
        func near(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, _ message: String) {
            precondition(simd_distance(actual,expected)<0.006,"\(message): \(actual) expected \(expected)")
        }
        func display(_ x: Float) -> Float { x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055 }
        let left = 32*128+32, right = 32*128+96
        near(render(.init(panels:[panel(blue)],projectionIndex:1))[left],[1,0,0,1],"Underlay must stay below projection")
        near(render(.init(panels:[panel(blue)],projectionIndex:0))[left],[0,0,1,1],"Overlay must stay above projection")
        near(render(.init(panels:[panel(texture([0,0,1,0]))],projectionIndex:0))[left],[0,0,1,1],"Ignoring source alpha must remain opaque")
        let purple = SIMD4<Float>(display(0.5),0,display(0.5),1)
        near(render(.init(panels:[panel(texture([0,0,1,0.5]),mode:.straight)],projectionIndex:0))[left],purple,"Straight alpha")
        near(render(.init(panels:[panel(texture([0,0,0.5,0.5]),mode:.premultiplied)],projectionIndex:0))[left],purple,"Premultiplied alpha")
        let order = OpenXRComposition(panels:[panel(green),panel(texture([0,0,1,0.5]),mode:.straight)],projectionIndex:1,projectionAlphaMode:.straight)
        near(render(order,projection:[1,0,0,0.5])[left],[display(0.25),display(0.25),display(0.5),1],"Underlay/projection/overlay declaration order")
        let under = OpenXRComposition(panels:[panel(green)],projectionIndex:1,projectionAlphaMode:.premultiplied)
        near(render(under,projection:[0.5,0,0,0.5],premultiplied:true)[left],
             [display(0.5),display(0.5),0,1],"Premultiplied projection preserves its underlay")
        near(render(.init(panels:[panel(green)],projectionIndex:1,projectionAlphaMode:.opaque),projection:[1,0,0,0])[left],
             [1,0,0,1],"Projection alpha ignored when source-alpha flag is absent")
        let onlyLeft = render(.init(panels:[panel(blue,eye:.left)],projectionIndex:0))
        near(onlyLeft[left],[0,0,1,1],"Left eye visibility");near(onlyLeft[right],[1,0,0,1],"Right eye must remain untouched")
        let onlyRight = render(.init(panels:[panel(blue,eye:.right)],projectionIndex:0))
        near(onlyRight[left],[1,0,0,1],"Left eye must remain untouched");near(onlyRight[right],[0,0,1,1],"Right eye visibility")
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:16,height:8,mipmapped:false)
        td.storageMode = .shared;td.usage = [.shaderRead,.pixelFormatView]
        let atlas = device.makeTexture(descriptor:td)!
        var bytes = [UInt8](repeating:255,count:16*8*4)
        for y in 0..<8 {for x in 0..<16 {let at=(y*16+x)*4;bytes[at]=0;bytes[at+1]=x<8 ? 0:255;bytes[at+2]=x<8 ? 255:0}}
        bytes.withUnsafeBytes {atlas.replace(region:MTLRegionMake2D(0,0,16,8),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:64)}
        var cropped = panel(atlas);cropped.uvRect=[0,0,0.5,1]
        let crop = render(.init(panels:[cropped],projectionIndex:0))
        near(crop[32*128+63],[0,0,1,1],"Atlas edge must not bleed adjacent eye/subimage")
        var tilted=panel(blue);tilted.orientation=simd_quatf(angle:.pi/3,axis:[0,1,0])
        let tilt=render(.init(panels:[tilted],projectionIndex:0))
        near(tilt[left],[0,0,1,1],"Tilted quad center");near(tilt[32*128+59],[1,0,0,1],"Tilted quad has geometric bounds")
        var locked=panel(blue);locked.headLocked=true
        let moved=simd_quatf(angle:.pi/3,axis:[0,1,0])
        near(render(.init(panels:[locked],projectionIndex:0),head:[3,2,1],rotation:moved)[left],[0,0,1,1],"VIEW quad follows head pose")
        near(render(.init(panels:[panel(blue)],projectionIndex:0),head:[3,2,1],rotation:moved)[left],[1,0,0,1],"World quad does not follow head")
        near(render(.init(panels:[panel(blue)],projectionIndex:nil))[left],[0,0,1,1],"Quad-only frame ignores projection carrier")
        var linear=panel(texture([0.25,0.25,0.25,1]));linear.colourSpace=1
        near(render(.init(panels:[linear],projectionIndex:0))[left],[display(0.25),display(0.25),display(0.25),1],"Linear input transfer")
        var sbytes=[UInt8](repeating:128,count:16*8*4);for i in stride(from:3,to:sbytes.count,by:4){sbytes[i]=255}
        sbytes.withUnsafeBytes {atlas.replace(region:MTLRegionMake2D(0,0,16,8),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:64)}
        var srgb=panel(atlas);srgb.colourSpace=2
        near(render(.init(panels:[srgb],projectionIndex:0))[left],[128/255,128/255,128/255,1],"sRGB view must decode before filtering exactly once")
        print("PASS: actual full scene Metal pipeline; quad order/underlay, three alpha modes, linear/sRGB transfer, eye masks, cropped UV clamp, tilted geometry, VIEW/world anchors and quad-only frames")
    }
}
