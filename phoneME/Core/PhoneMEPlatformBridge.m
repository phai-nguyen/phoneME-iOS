#import <UIKit/UIKit.h>

#include <stdint.h>
#include <string.h>
#include <zlib.h>

static NSURL *PhoneMEPlatformURL(NSString *value) {
    if (value.length == 0) {
        return nil;
    }

    NSURL *url = [NSURL URLWithString:value];
    if (url.scheme.length != 0) {
        return url;
    }

    NSString *escaped = [value stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLFragmentAllowedCharacterSet]];
    url = escaped == nil ? nil : [NSURL URLWithString:escaped];
    return url.scheme.length == 0 ? nil : url;
}

int32_t phoneme_ios_platform_request(const char *url_bytes) {
    if (url_bytes == NULL || url_bytes[0] == '\0') {
        return 0;
    }

    NSString *value = [NSString stringWithUTF8String:url_bytes];
    NSURL *url = PhoneMEPlatformURL(value);
    if (url == nil) {
        return 0;
    }

    __block BOOL canOpen = NO;
    void (^openRequest)(void) = ^{
        UIApplication *application = UIApplication.sharedApplication;
        canOpen = [application canOpenURL:url];
        if (canOpen) {
            [application openURL:url
                         options:@{}
               completionHandler:nil];
        }
    };

    if (NSThread.isMainThread) {
        openRequest();
    } else {
        dispatch_sync(dispatch_get_main_queue(), openRequest);
    }

    return canOpen ? 1 : 0;
}


int32_t phoneME_inflate_raw_zip(
    const uint8_t *source,
    uint32_t source_length,
    uint8_t *destination,
    uint32_t destination_capacity,
    uint32_t *output_length
) {
    if (source == NULL || destination == NULL || output_length == NULL ||
        source_length == 0 || destination_capacity == 0) {
        return 0;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)source_length;
    stream.next_out = destination;
    stream.avail_out = (uInt)destination_capacity;

    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        return 0;
    }

    const int status = inflate(&stream, Z_FINISH);
    *output_length = (uint32_t)stream.total_out;
    const int succeeded = status == Z_STREAM_END &&
        stream.total_out == destination_capacity &&
        stream.avail_in == 0;
    inflateEnd(&stream);
    return succeeded ? 1 : 0;
}
