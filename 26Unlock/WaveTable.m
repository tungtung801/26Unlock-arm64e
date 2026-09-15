#import "WaveTable.h"

static const NSInteger kWaveMap[6][4] = {
    { 8, 7, 7, 8 },
    { 6, 4, 4, 6 },
    { 3, 1, 1, 3 },
    { 2, 1, 1, 2 },
    { 3, 1, 1, 3 },
    { 5, 4, 4, 5 },
};

@implementation WaveTable

+ (CGPoint)center {
    return CGPointMake(1.5, 2.0);
}

+ (BOOL)isValidCol:(NSInteger)col row:(NSInteger)row {
    return col >= 0 && col <= 3 && row >= 0 && row <= 5;
}

+ (NSInteger)waveForCol:(NSInteger)col row:(NSInteger)row {
    if (![self isValidCol:col row:row]) {
        return 0;
    }
    return kWaveMap[row][col];
}

+ (double)microOffsetForCol:(NSInteger)col row:(NSInteger)row {
    // Exact control flow recovered from the original binary:
    // row == 1 and col == 0 or 3 => +0.015, otherwise 0.
    if (row == 1 && (col == 0 || col == 3)) {
        return 0.015;
    }
    return 0.0;
}

+ (double)delayForCol:(NSInteger)col
                  row:(NSInteger)row
        waveInterval:(double)waveInterval {
    NSInteger wave = [self waveForCol:col row:row];

    if (wave == 0) {
        return 0.0;
    }

    double delay =
        (double)(wave - 1) * waveInterval +
        [self microOffsetForCol:col row:row];

    // Exact binary behavior: waves 4+ receive one wave interval removed.
    if (wave >= 4) {
        delay -= 0.055;
    }

    return delay;
}

@end
