// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

// Only a single RIFE tier change may bypass normal filter-chain reconstruction.
static inline NSString *IIVERIFETierOnlyChange(NSArray<NSString *> *before, NSArray<NSString *> *after) {
    if (!before || before.count != after.count) return nil;
    NSString *result = nil;
    for (NSUInteger i = 0; i < before.count; i++) {
        if ([before[i] isEqual:after[i]]) continue;
        if (result) return nil;
        NSString *prefix = @"@iive-rife:iive-rife=";
        if (![before[i] hasPrefix:prefix] || ![after[i] hasPrefix:prefix]) return nil;
        NSMutableArray *old = [[[before[i] substringFromIndex:prefix.length] componentsSeparatedByString:@":"] mutableCopy];
        NSMutableArray *next = [[[after[i] substringFromIndex:prefix.length] componentsSeparatedByString:@":"] mutableCopy];
        NSArray *oldTiers = [old filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", @"tier="]];
        NSArray *nextTiers = [next filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@", @"tier="]];
        if (oldTiers.count != 1 || nextTiers.count != 1) return nil;
        NSString *tier = [nextTiers[0] substringFromIndex:5];
        if (![@[@"fast", @"balanced", @"hq"] containsObject:tier]) return nil;
        [old removeObject:oldTiers[0]]; [next removeObject:nextTiers[0]];
        if (![old isEqual:next]) return nil;
        result = tier;
    }
    return result;
}
