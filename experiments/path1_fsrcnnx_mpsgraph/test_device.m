#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSLog(@"Device: %@", device ? device.name : @"nil");
        if (!device) {
            NSLog(@"Metal device not available in this environment.");
            return 1;
        }
        MPSGraph *graph = [MPSGraph new];
        NSLog(@"MPSGraph initialized: %@", graph);
    }
    return 0;
}
