// Satori v2.30: a thin Objective-C++ face over libtorrent for streaming one file of a torrent (Swift sees only this header).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SatoriTorrentFile : NSObject
@property (nonatomic, readonly) int index;
@property (nonatomic, copy, readonly) NSString *path; // relative path inside the torrent
@property (nonatomic, readonly) long long size;
@end

@interface SatoriTorrent : NSObject
/// Starts a session that keeps its files under `savePath` (a cache folder: nothing there is kept on purpose).
- (instancetype)initWithSavePath:(NSString *)savePath;
/// Adds a magnet link; nothing is downloaded until a file is selected.
- (BOOL)addMagnet:(NSString *)magnet;
/// nil until the metadata (the file list) has arrived.
- (nullable NSArray<SatoriTorrentFile *> *)files;
/// Downloads only this file, front first.
- (BOOL)selectFile:(int)index;
/// Gives the pieces from `offset` of the selected file the nearest deadlines (the player is reading there now).
- (void)prioritizeFromOffset:(long long)offset;
/// How many bytes from `offset` of the selected file are already on disk, without a gap.
- (long long)availableBytesFromOffset:(long long)offset;
/// Absolute path of the selected file on disk (sparse until it is complete).
- (nullable NSString *)selectedFilePath;
- (long long)selectedFileSize;
/// Download speed in bytes per second, and the number of peers.
- (long long)downloadRate;
- (int)peerCount;
/// Stops the session and deletes everything it saved.
- (void)stopAndDelete;
@end

NS_ASSUME_NONNULL_END
