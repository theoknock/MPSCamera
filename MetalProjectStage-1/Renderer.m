//
//  Renderer.m
//  MetalProjectStage-1
//
//  Created by Xcode Developer on 6/2/21.
//

#import "Renderer.h"
#import "Camera.h"

@implementation Renderer
{
    id<MTLTexture>(^create_texture)(CVPixelBufferRef);
    void(^(^filter_texture)(id<MTLTexture>))(id<MTLCommandBuffer>, id<MTLTexture>);
    void(^draw_texture)(void(^)(id<MTLCommandBuffer>, id<MTLTexture>));
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view {
    if (self = [super init])
    {
        create_texture = ^ (CVMetalTextureCacheRef texture_cache_ref) {
           __block id<MTLTexture> texture = nil;
            MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
            return ^id<MTLTexture> _Nonnull (CVPixelBufferRef pixel_buffer) {
                CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
                {
                    CVMetalTextureRef metalTextureRef = NULL;
                    CVMetalTextureCacheCreateTextureFromImage(NULL, texture_cache_ref, pixel_buffer, NULL, pixelFormat, CVPixelBufferGetWidth(pixel_buffer), CVPixelBufferGetHeight(pixel_buffer), 0, &metalTextureRef);
                    texture = CVMetalTextureGetTexture(metalTextureRef);
                    CFRelease(metalTextureRef);
                }
                CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
                return texture;
            };
        }(^ (id<MTLDevice> device) {
            CFStringRef textureCacheKeys[2] = {kCVMetalTextureCacheMaximumTextureAgeKey, kCVMetalTextureUsage};
            float maximumTextureAge = (1.0 / view.preferredFramesPerSecond);
            CFNumberRef maximumTextureAgeValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &maximumTextureAge);
            MTLTextureUsage textureUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
            CFNumberRef textureUsageValue = CFNumberCreate(NULL, kCFNumberNSIntegerType, &textureUsage);
            CFTypeRef textureCacheValues[2] = {maximumTextureAgeValue, textureUsageValue};
            CFIndex textureCacheAttributesCount = 2;
            CFDictionaryRef cacheAttributes = CFDictionaryCreate(NULL, (const void **)textureCacheKeys, (const void **)textureCacheValues, textureCacheAttributesCount, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            
            CVMetalTextureCacheRef textureCache;
            CVMetalTextureCacheCreate(NULL, cacheAttributes, device, NULL, &textureCache);
            CFShow(cacheAttributes);
            CFRelease(textureUsageValue);
            CFRelease(cacheAttributes);
            return textureCache;
        }(view.preferredDevice));
        
        filter_texture = ^ (id<MTLDevice> device) {
            MPSImageHistogramInfo histogramInfo = {
                .numberOfHistogramEntries = 256,
                .histogramForAlpha = FALSE,
                .minPixelValue = simd_make_float4(0.0, 0.0, 0.0, 0.0),
                .maxPixelValue = simd_make_float4(1.0, 1.0, 1.0, 1.0)
            };
            MPSImageHistogram * calculation = [[MPSImageHistogram alloc] initWithDevice:device histogramInfo:&histogramInfo];
            MPSImageHistogramEqualization * equalization = [[MPSImageHistogramEqualization alloc] initWithDevice:calculation.device histogramInfo:&histogramInfo];
            size_t bufferLength = [calculation histogramSizeForSourceFormat:MTLPixelFormatBGRA8Unorm_sRGB];
            id<MTLBuffer> histogramInfoBuffer = [calculation.device newBufferWithLength:bufferLength options:MTLResourceStorageModePrivate];
            
            const float weights[9] = {
                -1.0, 0.0, 1.0,
                -2.0, 0.0, 2.0,
                -1.0, 0.0, 1.0
            };
            MPSImageConvolution * convolution = [[MPSImageConvolution alloc] initWithDevice:device kernelWidth:3 kernelHeight:3 weights:weights];
            [convolution setBias:0.0];
            
            MTLTextureDescriptor * descriptor = [MTLTextureDescriptor
                                                 texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                 width:view.currentDrawable.texture.width
                                                 height:view.currentDrawable.texture.height
                                                 mipmapped:FALSE];
            [descriptor setUsage:MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead];
            id<MTLTexture> newSourceTexture = [device newTextureWithDescriptor:descriptor];
            
            return ^ (id<MTLTexture> source_texture) {
                return ^ (id<MTLCommandBuffer> command_buffer, id<MTLTexture> destination_texture) {
                    [calculation encodeToCommandBuffer:command_buffer sourceTexture:source_texture histogram:histogramInfoBuffer histogramOffset:0];
                    [equalization encodeTransformToCommandBuffer:command_buffer sourceTexture:source_texture histogram:histogramInfoBuffer histogramOffset:0];
                    [equalization encodeToCommandBuffer:command_buffer sourceTexture:source_texture destinationTexture:newSourceTexture];
                    [convolution encodeToCommandBuffer:command_buffer sourceTexture:newSourceTexture destinationTexture:destination_texture];
                };
            };
        }(view.preferredDevice);
        
        draw_texture = ^ (MTKView * view, id<MTLCommandQueue> command_queue) {
            return ^ (void (^filter)(id<MTLCommandBuffer>, id<MTLTexture>)) {
                id<MTLCommandBuffer> commandBuffer = [command_queue commandBuffer];
                id<CAMetalDrawable> layerDrawable = [(CAMetalLayer *)(view.layer) nextDrawable];
                id<MTLTexture> drawableTexture = [layerDrawable texture];
                
                [commandBuffer enqueue];
                
                filter(commandBuffer, drawableTexture);
                
                [commandBuffer presentDrawable:layerDrawable];
                [commandBuffer commit];
            };
        }(view, [view.preferredDevice newCommandQueue]);
        
        [[Camera video] setVideoOutputDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate> _Nullable)self];
    }
    
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    draw_texture(filter_texture(create_texture(CMSampleBufferGetImageBuffer(sampleBuffer))));
}

@end
