// SPDX-License-Identifier: GPL-3.0-or-later
#import "../native/Player/Modern/RIFETierChange.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSString *old=@"@iive-rife:iive-rife=fps=48:tier=balanced:fallback=yes";
    NSString *next=@"@iive-rife:iive-rife=fps=48:tier=fast:fallback=yes";
    NSString *sr=@"@iive-sr:iive-fsrcnnx=tier=fast:split=0.0:fallback=yes";
    assert([IIVERIFETierOnlyChange(@[old],@[next]) isEqual:@"fast"]);
    assert([IIVERIFETierOnlyChange(@[old,sr],@[next,sr]) isEqual:@"fast"]);
    assert(!IIVERIFETierOnlyChange(@[old],@[old]));
    assert(!IIVERIFETierOnlyChange(@[old,sr],@[next]));
    assert(!IIVERIFETierOnlyChange(@[old],@[[next stringByReplacingOccurrencesOfString:@"48" withString:@"60"]]));
    assert(!IIVERIFETierOnlyChange(@[old],@[[next stringByReplacingOccurrencesOfString:@"yes" withString:@"no"]]));
    assert(!IIVERIFETierOnlyChange(@[old],@[[next stringByReplacingOccurrencesOfString:@"tier=fast" withString:@"tier=fast:tier=hq"]]));
    assert(!IIVERIFETierOnlyChange(@[old],@[[next stringByReplacingOccurrencesOfString:@"tier=fast" withString:@"tier=invalid"]]));
    puts("PASS: only isolated RIFE tier changes qualify for the no-seek command path");
} }
