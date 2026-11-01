#include "OWLPresenter.hpp"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <objc/message.h>
#include <time.h>

#include "OWLHost.hpp"

namespace owl {

uint64_t NowNanos() {
  return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

namespace {

constexpr size_t kMaxSlots = 4;
constexpr OSType kBGRA = 'BGRA';

struct Slot {
  IOSurfaceRef surface = nullptr;
  id<MTLTexture> texture = nil;
  uint32_t surface_id = 0;
  bool awaiting_ack = false;
};

struct Chain {
  std::vector<Slot> slots;
  uint32_t current_id = 0;
  uint64_t sequence = 0;
  uint64_t dropped = 0;
};

id<MTLDevice> SharedDevice() {
  static id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  return device;
}

id<MTLCommandQueue> SharedQueue() {
  static id<MTLCommandQueue> queue = [SharedDevice() newCommandQueue];
  return queue;
}

id<MTLTexture> TextureForSurface(IOSurfaceRef surface) {
  MTLTextureDescriptor* descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                         width:IOSurfaceGetWidth(surface)
                                                        height:IOSurfaceGetHeight(surface)
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  return [SharedDevice() newTextureWithDescriptor:descriptor iosurface:surface plane:0];
}

IOSurfaceRef CreateSurface(int width, int height) {
  const size_t bytes_per_row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 4);
  NSDictionary* properties = @{
    (id)kIOSurfaceWidth : @(width),
    (id)kIOSurfaceHeight : @(height),
    (id)kIOSurfaceBytesPerElement : @4,
    (id)kIOSurfaceBytesPerRow : @(bytes_per_row),
    (id)kIOSurfacePixelFormat : @(kBGRA),
  };
  return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

void ReleaseSlot(Slot& slot) {
  slot.texture = nil;
  if (slot.surface != nullptr) {
    CFRelease(slot.surface);
    slot.surface = nullptr;
  }
}

bool SizeMatches(const Slot& slot, int width, int height) {
  return (int)IOSurfaceGetWidth(slot.surface) == width &&
         (int)IOSurfaceGetHeight(slot.surface) == height;
}

/// A slot that neither the client nor the window server is reading, or nullptr when all are busy.
Slot* AcquireSlot(Chain& chain, int width, int height) {
  for (auto it = chain.slots.begin(); it != chain.slots.end();) {
    bool idle = !it->awaiting_ack && it->surface_id != chain.current_id &&
                !IOSurfaceIsInUse(it->surface);
    if (idle && !SizeMatches(*it, width, height)) {
      ReleaseSlot(*it);
      it = chain.slots.erase(it);
    } else {
      ++it;
    }
  }
  for (Slot& slot : chain.slots) {
    if (SizeMatches(slot, width, height) && !slot.awaiting_ack &&
        slot.surface_id != chain.current_id && !IOSurfaceIsInUse(slot.surface)) {
      return &slot;
    }
  }
  if (chain.slots.size() >= kMaxSlots) {
    return nullptr;
  }
  IOSurfaceRef surface = CreateSurface(width, height);
  if (surface == nullptr) {
    return nullptr;
  }
  Slot slot;
  slot.surface = surface;
  slot.surface_id = IOSurfaceGetID(surface);
  chain.slots.push_back(slot);
  return &chain.slots.back();
}

const Slot* CurrentSlot(const Chain& chain) {
  for (const Slot& slot : chain.slots) {
    if (slot.surface_id == chain.current_id && chain.current_id != 0) {
      return &slot;
    }
  }
  return nullptr;
}

CGImageRef CreateImage(IOSurfaceRef surface) {
  if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) {
    return nullptr;
  }
  const size_t width = IOSurfaceGetWidth(surface);
  const size_t height = IOSurfaceGetHeight(surface);
  const size_t bytes_per_row = IOSurfaceGetBytesPerRow(surface);
  CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                                static_cast<const UInt8*>(IOSurfaceGetBaseAddress(surface)),
                                (CFIndex)(bytes_per_row * height));
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
  if (data == nullptr) {
    return nullptr;
  }
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CFRelease(data);
  CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGImageRef image = CGImageCreate(
      width, height, 8, 32, bytes_per_row, color_space,
      (CGBitmapInfo)kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
      provider, nullptr, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(color_space);
  CGDataProviderRelease(provider);
  return image;
}

using CGSMainConnectionIDFunction = uint32_t (*)();

}  // namespace

struct Presenter::Impl {
  uint64_t view_id = 0;
  OWLRenderMode mode = OWLRenderModeRemoteLayer;
  double width = 1;
  double height = 1;
  double scale = 1;
  Chain page;
  Chain popup;
  bool popup_visible = false;
  CGRect popup_rect = CGRectZero;
  id context = nil;
  CALayer* root = nil;
  CALayer* page_layer = nil;
  CALayer* popup_layer = nil;

  Chain& ChainFor(OWLLayer layer) { return layer == OWLLayerPopup ? popup : page; }

  void UpdateRootGeometry() {
    if (root == nil) {
      return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    root.bounds = CGRectMake(0, 0, width, height);
    [CATransaction commit];
  }

  void Deliver(OWLLayer layer, Slot& slot, int pixel_width, int pixel_height,
               uint64_t paint_nanos, uint64_t blit_nanos) {
    Chain& chain = ChainFor(layer);
    chain.sequence += 1;
    const double point_width = pixel_width / scale;
    const double point_height = pixel_height / scale;
    if (mode == OWLRenderModeRemoteLayer) {
      CALayer* target = layer == OWLLayerPopup ? popup_layer : page_layer;
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      target.contents = (__bridge id)slot.surface;
      if (layer == OWLLayerPopup) {
        target.frame = CGRectMake(popup_rect.origin.x, popup_rect.origin.y, point_width,
                                  point_height);
        target.hidden = !popup_visible;
      } else {
        target.frame = CGRectMake(0, 0, point_width, point_height);
      }
      [CATransaction commit];
      [CATransaction flush];
      chain.current_id = slot.surface_id;
      Host::Get().Send(OWLMessageKindPresented, 0, view_id,
                       Encoder()
                           .U64(OWLFieldLayer, layer)
                           .U64(OWLFieldSequence, chain.sequence)
                           .U64(OWLFieldHostTimestampNanos, paint_nanos)
                           .U64(OWLFieldHostBlitNanos, blit_nanos)
                           .U64(OWLFieldPresentedNanos, NowNanos())
                           .U64(OWLFieldDroppedFrames, chain.dropped));
      return;
    }
    mach_port_t port = IOSurfaceCreateMachPort(slot.surface);
    if (port == MACH_PORT_NULL) {
      Host::Get().ReportError(view_id, OWLHostErrorRenderFailed,
                              "IOSurfaceCreateMachPort returned no port.");
      return;
    }
    slot.awaiting_ack = true;
    chain.current_id = slot.surface_id;
    Encoder fields;
    fields.U64(OWLFieldLayer, layer)
        .U64(OWLFieldSequence, chain.sequence)
        .U64(OWLFieldSurfaceIndex, slot.surface_id)
        .U64(OWLFieldPixelWidth, (uint64_t)pixel_width)
        .U64(OWLFieldPixelHeight, (uint64_t)pixel_height)
        .Double(OWLFieldScale, scale)
        .U64(OWLFieldHostTimestampNanos, paint_nanos)
        .U64(OWLFieldHostBlitNanos, blit_nanos)
        .U64(OWLFieldDroppedFrames, chain.dropped);
    if (layer == OWLLayerPopup) {
      fields.Double(OWLFieldX, popup_rect.origin.x)
          .Double(OWLFieldY, popup_rect.origin.y)
          .Bool(OWLFieldVisible, popup_visible);
    }
    Host::Get().Send(OWLMessageKindFrame, 0, view_id, fields, port, MACH_MSG_TYPE_COPY_SEND);
    mach_port_deallocate(mach_task_self(), port);
  }
};

Presenter::Presenter(uint64_t view_id, OWLRenderMode mode) : impl_(std::make_unique<Impl>()) {
  impl_->view_id = view_id;
  impl_->mode = mode;
}

Presenter::~Presenter() {
  for (Slot& slot : impl_->page.slots) {
    ReleaseSlot(slot);
  }
  for (Slot& slot : impl_->popup.slots) {
    ReleaseSlot(slot);
  }
}

bool Presenter::Start(std::string* error) {
  if (SharedDevice() == nil || SharedQueue() == nil) {
    *error = "No Metal device is available for copying frames.";
    return false;
  }
  if (impl_->mode != OWLRenderModeRemoteLayer) {
    return true;
  }
  // Private API: CAContext and CGSMainConnectionID. Resolved at run time so their absence is a
  // reported error, not a launch failure. See DESIGN.md, "Rendering risks".
  Class context_class = NSClassFromString(@"CAContext");
  SEL factory = NSSelectorFromString(@"contextWithCGSConnection:options:");
  auto main_connection =
      reinterpret_cast<CGSMainConnectionIDFunction>(dlsym(RTLD_DEFAULT, "CGSMainConnectionID"));
  if (context_class == Nil || ![context_class respondsToSelector:factory] ||
      main_connection == nullptr) {
    *error = "The private CAContext API is unavailable on this macOS version.";
    return false;
  }
  using FactoryFunction = id (*)(Class, SEL, uint32_t, NSDictionary*);
  id context = reinterpret_cast<FactoryFunction>(objc_msgSend)(context_class, factory,
                                                               main_connection(), @{});
  NSNumber* context_id = [context respondsToSelector:NSSelectorFromString(@"contextId")]
                             ? [context valueForKey:@"contextId"]
                             : nil;
  if (context == nil || context_id.unsignedIntValue == 0) {
    *error = "CAContext creation failed; the window server refused a remote context.";
    return false;
  }
  CALayer* root = [CALayer layer];
  root.anchorPoint = CGPointZero;
  root.position = CGPointZero;
  root.geometryFlipped = YES;
  root.masksToBounds = YES;
  root.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
  CALayer* page_layer = [CALayer layer];
  page_layer.anchorPoint = CGPointZero;
  CALayer* popup_layer = [CALayer layer];
  popup_layer.anchorPoint = CGPointZero;
  popup_layer.hidden = YES;
  [root addSublayer:page_layer];
  [root addSublayer:popup_layer];
  [context setValue:root forKey:@"layer"];
  impl_->context = context;
  impl_->root = root;
  impl_->page_layer = page_layer;
  impl_->popup_layer = popup_layer;
  impl_->UpdateRootGeometry();
  [CATransaction flush];
  Host::Get().Send(OWLMessageKindLayerContext, 0, impl_->view_id,
                   Encoder().U64(OWLFieldContextID, context_id.unsignedIntValue));
  return true;
}

void Presenter::SetGeometry(double width, double height, double scale) {
  impl_->width = width;
  impl_->height = height;
  impl_->scale = scale;
  impl_->UpdateRootGeometry();
}

void Presenter::PresentAccelerated(OWLLayer layer, IOSurfaceRef source, int x, int y, int width,
                                   int height, uint64_t paint_nanos) {
  if (IOSurfaceGetPixelFormat(source) != kBGRA) {
    Host::Get().ReportError(impl_->view_id, OWLHostErrorRenderFailed,
                            "CEF delivered a frame that is not BGRA.");
    return;
  }
  Chain& chain = impl_->ChainFor(layer);
  Slot* slot = AcquireSlot(chain, width, height);
  if (slot == nullptr) {
    chain.dropped += 1;
    return;
  }
  if (slot->texture == nil) {
    slot->texture = TextureForSurface(slot->surface);
  }
  id<MTLTexture> source_texture = TextureForSurface(source);
  if (source_texture == nil || slot->texture == nil) {
    Host::Get().ReportError(impl_->view_id, OWLHostErrorRenderFailed,
                            "Could not wrap a frame IOSurface in a Metal texture.");
    return;
  }
  const uint64_t blit_start = NowNanos();
  id<MTLCommandBuffer> buffer = [SharedQueue() commandBuffer];
  id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
  [blit copyFromTexture:source_texture
             sourceSlice:0
             sourceLevel:0
            sourceOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)
              sourceSize:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1)
               toTexture:slot->texture
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  [buffer commit];
  // The source returns to CEF's pool when this callback returns, so the copy must finish first.
  [buffer waitUntilCompleted];
  if (buffer.status != MTLCommandBufferStatusCompleted) {
    const char* detail = buffer.error.localizedDescription.UTF8String;
    Host::Get().ReportError(impl_->view_id, OWLHostErrorRenderFailed,
                            std::string("Frame copy failed: ") +
                                (detail != nullptr ? detail : "unknown Metal error"));
    return;
  }
  impl_->Deliver(layer, *slot, width, height, paint_nanos, NowNanos() - blit_start);
}

void Presenter::PresentPixels(OWLLayer layer, const void* bgra, int width, int height,
                              uint64_t paint_nanos) {
  Chain& chain = impl_->ChainFor(layer);
  Slot* slot = AcquireSlot(chain, width, height);
  if (slot == nullptr) {
    chain.dropped += 1;
    return;
  }
  const uint64_t copy_start = NowNanos();
  if (IOSurfaceLock(slot->surface, 0, nullptr) != kIOReturnSuccess) {
    Host::Get().ReportError(impl_->view_id, OWLHostErrorRenderFailed, "IOSurfaceLock failed.");
    return;
  }
  auto* destination = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(slot->surface));
  const size_t destination_stride = IOSurfaceGetBytesPerRow(slot->surface);
  const auto* source = static_cast<const uint8_t*>(bgra);
  const size_t source_stride = (size_t)width * 4;
  for (int row = 0; row < height; ++row) {
    memcpy(destination + (size_t)row * destination_stride, source + (size_t)row * source_stride,
           source_stride);
  }
  IOSurfaceUnlock(slot->surface, 0, nullptr);
  impl_->Deliver(layer, *slot, width, height, paint_nanos, NowNanos() - copy_start);
}

void Presenter::SetPopupVisible(bool visible) {
  impl_->popup_visible = visible;
  if (!visible) {
    impl_->popup.current_id = 0;
  }
  if (impl_->mode == OWLRenderModeRemoteLayer) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    impl_->popup_layer.hidden = !visible;
    if (!visible) {
      impl_->popup_layer.contents = nil;
    }
    [CATransaction commit];
    [CATransaction flush];
  } else {
    Host::Get().Send(OWLMessageKindPopupVisibility, 0, impl_->view_id,
                     Encoder().Bool(OWLFieldVisible, visible));
  }
}

void Presenter::SetPopupRect(double x, double y, double width, double height) {
  impl_->popup_rect = CGRectMake(x, y, width, height);
}

void Presenter::AcknowledgeFrame(uint32_t surface_id) {
  for (Chain* chain : {&impl_->page, &impl_->popup}) {
    for (Slot& slot : chain->slots) {
      if (slot.surface_id == surface_id) {
        slot.awaiting_ack = false;
      }
    }
  }
}

bool Presenter::HasFrame() const {
  return CurrentSlot(impl_->page) != nullptr;
}

bool Presenter::Snapshot(std::vector<uint8_t>* png, std::string* error) const {
  const Slot* page = CurrentSlot(impl_->page);
  if (page == nullptr) {
    *error = "The page has not rendered a frame yet.";
    return false;
  }
  CGImageRef page_image = CreateImage(page->surface);
  if (page_image == nullptr) {
    *error = "Could not read the page frame.";
    return false;
  }
  const size_t width = CGImageGetWidth(page_image);
  const size_t height = CGImageGetHeight(page_image);
  CGColorSpaceRef color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(
      nullptr, width, height, 8, 0, color_space,
      (CGBitmapInfo)kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(color_space);
  if (context == nullptr) {
    CGImageRelease(page_image);
    *error = "Could not allocate the snapshot bitmap.";
    return false;
  }
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), page_image);
  CGImageRelease(page_image);
  const Slot* popup = impl_->popup_visible ? CurrentSlot(impl_->popup) : nullptr;
  if (popup != nullptr) {
    CGImageRef popup_image = CreateImage(popup->surface);
    if (popup_image != nullptr) {
      const double scale = impl_->scale;
      const double popup_width = (double)CGImageGetWidth(popup_image);
      const double popup_height = (double)CGImageGetHeight(popup_image);
      // Popup rects are top-left based; Core Graphics is bottom-left based.
      CGRect rect = CGRectMake(impl_->popup_rect.origin.x * scale,
                               (double)height - impl_->popup_rect.origin.y * scale - popup_height,
                               popup_width, popup_height);
      CGContextDrawImage(context, rect, popup_image);
      CGImageRelease(popup_image);
    }
  }
  CGImageRef composite = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (composite == nullptr) {
    *error = "Could not compose the snapshot.";
    return false;
  }
  CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, nullptr);
  bool ok = false;
  if (destination != nullptr) {
    CGImageDestinationAddImage(destination, composite, nullptr);
    ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(composite);
  if (ok) {
    const UInt8* bytes = CFDataGetBytePtr(data);
    png->assign(bytes, bytes + CFDataGetLength(data));
  } else {
    *error = "PNG encoding failed.";
  }
  CFRelease(data);
  return ok;
}

}  // namespace owl
