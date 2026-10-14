#import <errno.h>
#import <sys/xattr.h>

// Finder custom icons add unsigned display metadata that strict code validation
// rejects. Normalize only the private staging copy; keep every signature check
// and all other extended attributes intact. Never follow a symbolic link.
static inline int ClashFXRemoveStagedBundleDisplayMetadata(const char *path) {
    const char *attributes[] = {"com.apple.FinderInfo", "com.apple.ResourceFork"};
    for (unsigned int index = 0; index < 2; index++) {
        if (removexattr(path, attributes[index], XATTR_NOFOLLOW) != 0 && errno != ENOATTR) {
            return errno;
        }
    }
    return 0;
}
