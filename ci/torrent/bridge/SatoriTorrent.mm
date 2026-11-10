#import "SatoriTorrent.h"

#include <libtorrent/session.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/session_stats.hpp>
#include <algorithm>
#include <map>
#include <string>
#include <vector>
#include <mutex>
#include <memory>

@interface SatoriTorrentFile ()
- (instancetype)initWithIndex:(int)index path:(NSString *)path size:(long long)size;
@end

@implementation SatoriTorrentFile
- (instancetype)initWithIndex:(int)index path:(NSString *)path size:(long long)size {
    if ((self = [super init])) {
        _index = index;
        _path = [path copy];
        _size = size;
    }
    return self;
}
@end

@implementation SatoriTorrent {
    std::unique_ptr<lt::session> _session;
    lt::torrent_handle _handle;
    NSString *_savePath;
    int _selected;
    bool _configured;
    std::mutex _lock;
    std::map<std::string, int> _ends; // why peer connections ended, by reason
    int _attempts;
    int _dhtNodes;
}

- (instancetype)initWithSavePath:(NSString *)savePath {
    if ((self = [super init])) {
        _savePath = [savePath copy];
        _selected = -1;
        _configured = false;
        _attempts = 0;
        _dhtNodes = -1;
        [[NSFileManager defaultManager] createDirectoryAtPath:savePath withIntermediateDirectories:YES attributes:nil error:nil];
        lt::settings_pack pack;
        pack.set_str(lt::settings_pack::user_agent, "Satori/2.30");
        pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0"); // IPv6 too: mobile networks
        pack.set_bool(lt::settings_pack::enable_dht, true);
        pack.set_bool(lt::settings_pack::enable_lsd, false);
        pack.set_int(lt::settings_pack::upload_rate_limit, 64 * 1024); // streaming, not seeding
        pack.set_int(lt::settings_pack::alert_mask, lt::alert_category::error | lt::alert_category::status
                     | lt::alert_category::peer | lt::alert_category::connect);
        _session = std::make_unique<lt::session>(pack);
    }
    return self;
}

- (BOOL)addMagnet:(NSString *)magnet {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        lt::error_code ec;
        lt::add_torrent_params params = lt::parse_magnet_uri(std::string(magnet.UTF8String), ec);
        if (ec) {
            return NO;
        }
        params.save_path = std::string(_savePath.UTF8String);
        _handle = _session->add_torrent(std::move(params));
        return _handle.is_valid() ? YES : NO;
    } catch (...) {
        return NO;
    }
}

/// With the metadata in, everything is switched off at once: the file is chosen by the app.
- (void)configureIfNeeded {
    if (_configured || !_handle.is_valid()) {
        return;
    }
    auto info = _handle.torrent_file();
    if (!info) {
        return;
    }
    _handle.prioritize_files(std::vector<lt::download_priority_t>(info->num_files(), lt::dont_download));
    _configured = true;
}

- (nullable NSArray<SatoriTorrentFile *> *)files {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        if (!_handle.is_valid()) {
            return nil;
        }
        auto info = _handle.torrent_file();
        if (!info) {
            return nil;
        }
        [self configureIfNeeded];
        NSMutableArray *result = [NSMutableArray array];
        const lt::file_storage &fs = info->files();
        for (int i = 0; i < fs.num_files(); i++) {
            lt::file_index_t index(i);
            NSString *path = [NSString stringWithUTF8String:fs.file_path(index).c_str()] ?: @"";
            [result addObject:[[SatoriTorrentFile alloc] initWithIndex:i path:path size:fs.file_size(index)]];
        }
        return result;
    } catch (...) {
        return nil;
    }
}

- (BOOL)selectFile:(int)index {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        auto info = _handle.torrent_file();
        if (!info || index < 0 || index >= info->num_files()) {
            return NO;
        }
        [self configureIfNeeded];
        _handle.prioritize_files(std::vector<lt::download_priority_t>(info->num_files(), lt::dont_download));
        _handle.file_priority(lt::file_index_t(index), lt::top_priority);
        _selected = index;
        [self prioritizeLocked:0];
        return YES;
    } catch (...) {
        return NO;
    }
}

- (void)prioritizeLocked:(long long)offset {
    auto info = _handle.torrent_file();
    if (!info || _selected < 0) {
        return;
    }
    lt::file_index_t file(_selected);
    long long size = info->files().file_size(file);
    if (offset < 0 || offset >= size) {
        return;
    }
    lt::peer_request first = info->map_file(file, offset, 1);
    // the next ~24 MB (2 to 24 pieces), the nearest first: a deadline in milliseconds from now. With 16 MB pieces 24 of
    // them were 384 MB wanted at once, and the first one took minutes.
    int ahead = static_cast<int>((24LL * 1024 * 1024 + info->piece_length() - 1) / info->piece_length());
    ahead = std::max(2, std::min(24, ahead));
    int deadline = 0;
    for (int i = 0; i < ahead; i++) {
        lt::piece_index_t piece(static_cast<int>(first.piece) + i);
        if (static_cast<int>(piece) >= info->num_pieces()) {
            break;
        }
        if (!_handle.have_piece(piece)) {
            _handle.set_piece_deadline(piece, deadline);
            deadline += 400;
        }
    }
}

- (void)prioritizeFromOffset:(long long)offset {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        [self prioritizeLocked:offset];
    } catch (...) {
    }
}

- (long long)availableBytesFromOffset:(long long)offset {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        auto info = _handle.torrent_file();
        if (!info || _selected < 0) {
            return 0;
        }
        lt::file_index_t file(_selected);
        long long size = info->files().file_size(file);
        if (offset < 0 || offset >= size) {
            return 0;
        }
        lt::peer_request request = info->map_file(file, offset, 1);
        long long available = 0;
        int piece = static_cast<int>(request.piece);
        long long inPiece = request.start;
        while (piece < info->num_pieces() && _handle.have_piece(lt::piece_index_t(piece))) {
            available += info->piece_size(lt::piece_index_t(piece)) - inPiece;
            inPiece = 0;
            piece++;
            if (offset + available >= size) {
                return size - offset;
            }
        }
        return available;
    } catch (...) {
        return 0;
    }
}

- (nullable NSString *)selectedFilePath {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        auto info = _handle.torrent_file();
        if (!info || _selected < 0) {
            return nil;
        }
        std::string relative = info->files().file_path(lt::file_index_t(_selected));
        return [_savePath stringByAppendingPathComponent:[NSString stringWithUTF8String:relative.c_str()]];
    } catch (...) {
        return nil;
    }
}

- (long long)selectedFileSize {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        auto info = _handle.torrent_file();
        if (!info || _selected < 0) {
            return 0;
        }
        return info->files().file_size(lt::file_index_t(_selected));
    } catch (...) {
        return 0;
    }
}

- (long long)downloadedBytes {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        return _handle.is_valid() ? _handle.status({}).total_wanted_done : 0;
    } catch (...) {
        return 0;
    }
}

- (long long)downloadRate {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        return _handle.is_valid() ? _handle.status({}).download_payload_rate : 0;
    } catch (...) {
        return 0;
    }
}

- (int)peerCount {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        return _handle.is_valid() ? _handle.status({}).num_peers : 0;
    } catch (...) {
        return 0;
    }
}

- (NSString *)diagnostics {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        if (!_session || !_handle.is_valid()) {
            return @"";
        }
        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        for (lt::alert *a : alerts) {
            if (auto *d = lt::alert_cast<lt::peer_disconnected_alert>(a)) {
                _ends[d->error.message()]++;
            } else if (auto *e = lt::alert_cast<lt::peer_error_alert>(a)) {
                _ends[e->error.message()]++;
            } else if (lt::alert_cast<lt::peer_connect_alert>(a)) {
                _attempts++;
            } else if (auto *s = lt::alert_cast<lt::dht_stats_alert>(a)) {
                int nodes = 0;
                for (auto const &bucket : s->routing_table) {
                    nodes += bucket.num_nodes;
                }
                _dhtNodes = nodes;
            }
        }
        _session->post_dht_stats(); // answered by the next call

        lt::torrent_status st = _handle.status({});
        std::string out = "пиров " + std::to_string(st.num_peers) + ", известно " + std::to_string(st.list_peers)
            + ", попыток " + std::to_string(_attempts) + ", DHT-узлов " + (_dhtNodes < 0 ? std::string("?") : std::to_string(_dhtNodes));
        for (const lt::announce_entry &tracker : _handle.trackers()) {
            std::string state = "ответа пока нет";
            for (const auto &endpoint : tracker.endpoints) {
                const auto &v1 = endpoint.info_hashes[lt::protocol_version::V1];
                if (v1.last_error) {
                    state = v1.last_error.message();
                } else if (v1.start_sent && v1.fails == 0) {
                    state = "ответил";
                    break;
                }
                if (!v1.message.empty()) {
                    state += " (" + v1.message + ")";
                }
            }
            std::string url = tracker.url;
            auto from = url.find("://");
            from = from == std::string::npos ? 0 : from + 3;
            out += "\n" + url.substr(from, url.find_first_of(":/", from) - from) + ": " + state;
        }
        std::vector<std::pair<int, std::string>> ends;
        for (auto const &entry : _ends) {
            ends.emplace_back(entry.second, entry.first);
        }
        std::sort(ends.rbegin(), ends.rend());
        for (size_t i = 0; i < ends.size() && i < 3; i++) {
            out += "\nобрыв ×" + std::to_string(ends[i].first) + ": " + ends[i].second;
        }
        return [NSString stringWithUTF8String:out.c_str()] ?: @"";
    } catch (...) {
        return @"";
    }
}

- (void)stopAndDelete {
    std::lock_guard<std::mutex> guard(_lock);
    try {
        if (_session && _handle.is_valid()) {
            _session->remove_torrent(_handle, lt::session::delete_files);
        }
        _session.reset();
    } catch (...) {
    }
    [[NSFileManager defaultManager] removeItemAtPath:_savePath error:nil];
}
@end
