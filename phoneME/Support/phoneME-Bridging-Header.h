#import "../../Core/include/JarArchive.h"
#import "../../Core/include/PhoneMECore.h"

int32_t phoneME_inflate_raw_zip(
    const uint8_t *source,
    uint32_t source_length,
    uint8_t *destination,
    uint32_t destination_capacity,
    uint32_t *output_length
);
