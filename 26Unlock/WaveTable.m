#import "WaveTable.h"

static const NSInteger kWaveMap[4][6] = {
    { 8, 7, 7, 8, 6, 4 },
    { 4, 6, 3, 1, 1, 3 },
    { 2, 1, 1, 2, 3, 1 },
    { 1, 3, 5, 4, 4, 5 },
};

@implementation WaveTable

+ (CGPoint)center {
    return CGPointMake(1.5, 2.5);
}

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row {
    return col >= 0 && col <= 3 && row >= 0 && row <= 5;
}

+ (NSInteger)waveForCol:(NSInteger)col row:(NSInteger)row {
    if (![self isValidCol:col row:row]) return 0;
    return kWaveMap[col][row];
}

+ (double)microOffsetForCol:(NSInteger)col row:(NSInteger)row {
    // Recovered from the binary: only two edge/corner positions receive
    // the non-zero micro offset. Exact placement is retained as a named
    // constant so it can be adjusted independently during A12 testing.
    if (col == 1 && (row == 0 || row == 3)) return 0.015;
    return 0.0;
}

+ (double)delayForCol:(NSInteger)col row:(NSInteger)row waveInterval:(double)waveInterval {
    NSInteger wave = [self waveForCol:col row:row];
    if (wave == 0) return 0.0;
    double delay = (double)(wave - 1) * waveInterval + [self microOffsetForCol:col row:row];
    if (wave >= 4) delay -= 0.0001;
    return delay;
}

@end
