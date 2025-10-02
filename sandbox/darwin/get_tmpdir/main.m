#import <Foundation/Foundation.h>

int main() {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *tmpDir = [[fm temporaryDirectory] path];
  printf("%s\n", [tmpDir UTF8String]);
}
