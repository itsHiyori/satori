# v2.30: watching online. «Видео» → «+» → «Смотреть онлайн»: the title is found in Jimaku, a release with the episode on
# Nyaa, the file of the episode inside it (as in anicli-ru-jimaku), and the player gets it from a local server while
# the torrent downloads; the Jimaku subtitles are put next to the address the player is given. Nothing is kept: the
# downloaded part is deleted when the player is closed.
# Настройки → Диагностика → «Проверки»: the build number, free space, Jimaku, Nyaa, the torrent engine with the local
# server, showing a screen; the steps of «Смотреть онлайн» go to the trail.
import os
import pathlib


def once(text, old, new, label):
    assert text.count(old) == 1, "pattern not found exactly once: " + label
    return text.replace(old, new)


here = pathlib.Path(__file__).resolve().parent
hv = pathlib.Path("src/safari/iOS (App)/HelpView.swift")
s = hv.read_text(encoding="utf-8")

# shown by UIKit, like the folder picker next to it: a navigationDestination, a hidden NavigationLink and a sheet
# set from this menu never opened
s = once(s, '''                            Label("Привязать папку (iTorrent)", systemImage: "link")
                        }
''', '''                            Label("Привязать папку (iTorrent)", systemImage: "link")
                        }
                        Button {
                            onlinePresenter.present()
                        } label: {
                            Label("Смотреть онлайн", systemImage: "play.circle")
                        }
''', "online menu item")
# Keep the presenter alive with the video screen, and anchor it next to the working YouTube sheet.
s = once(s, "    @State private var showYouTube = false\n",
         "    @State private var showYouTube = false\n    @StateObject private var onlinePresenter = OnlineScreenPresenter()\n",
         "online presenter state")
s = once(s, '''        .sheet(isPresented: $showYouTube) {
''', '''        .background(OnlinePresentationAnchor(presenter: onlinePresenter).frame(width: 0, height: 0))
        .alert("Не удалось открыть", isPresented: Binding(
            get: { onlinePresenter.failure != nil },
            set: { if !$0 { onlinePresenter.failure = nil } }
        )) {
            Button("ОК", role: .cancel) { onlinePresenter.failure = nil }
        } message: {
            Text(onlinePresenter.failure ?? "")
        }
        .sheet(isPresented: $showYouTube) {
''', "online presentation anchor")
# Настройки → Диагностика: the checks of the phone (network, Jimaku, Nyaa, the torrent engine, showing a screen)
s = once(s, '''                Text("Синхронизация с расширением")
            }
''', '''                Text("Синхронизация с расширением")
            }

            if #available(iOS 16.0, *) {
                DiagnosticChecksSection()
            }
''', "diagnostics checks")
swift = (here / "v230-stream.swift").read_text(encoding="utf-8")
s = s.rstrip("\n") + "\n" + swift.replace("@@BUILD@@", os.environ.get("GITHUB_RUN_NUMBER", "локальная"))
hv.write_text(s, encoding="utf-8")

# ---------- the Xcode project: the bridge library for the app target only ----------
pb = pathlib.Path("src/safari/Yomikiri.xcodeproj/project.pbxproj")
p = pb.read_text(encoding="utf-8")
marker = 'INFOPLIST_FILE = "iOS (App)/Info.plist";'
assert p.count(marker) == 2, "the app target has two configurations"
out, at, blocks = [], 0, 0
while True:
    i = p.find(marker, at)
    if i < 0:
        out.append(p[at:])
        break
    begin = p.rfind("buildSettings = {", 0, i)
    end = p.find("\n\t\t\t};", i)
    block = p[begin:end]
    block = once(block, 'SWIFT_OBJC_BRIDGING_HEADER = "";', 'SWIFT_OBJC_BRIDGING_HEADER = "$(SRCROOT)/satori-torrent/SatoriBridging.h";\n'
                 '\t\t\t\tHEADER_SEARCH_PATHS = "$(SRCROOT)/satori-torrent";\n'
                 '\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++17";', "bridging header")
    block = once(block, '''				OTHER_LDFLAGS = (
					"-framework",
					SafariServices,
					"-framework",
					WebKit,
''', '''				OTHER_LDFLAGS = (
					"-framework",
					SafariServices,
					"-framework",
					WebKit,
					"-framework",
					SystemConfiguration,
					"-framework",
					CoreFoundation,
					"-L$(SRCROOT)/satori-torrent",
					"-lSatoriTorrent",
					"-lc++",
''', "link flags")
    out.append(p[at:begin] + block)
    at = end
    blocks += 1
assert blocks == 2
pb.write_text("".join(out), encoding="utf-8")
print("v2.30 online watching applied")
