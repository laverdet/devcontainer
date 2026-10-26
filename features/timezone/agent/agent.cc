// timezone-agent: publishes the host's time zone where containers can read it.
//
// The agent keeps two files up to date in a directory that dev containers
// bind-mount read-only:
//   localtime  the zone data (TZif) the host's /etc/localtime resolves to
//   zone       its IANA name plus a newline; empty when the name is unknown
// Each is replaced by writing a temporary file and renaming it into place, so
// a container never sees a partial file. A container whose own /etc/localtime
// is a symlink to the mounted copy follows the host from then on with no
// process of its own: every program it starts reads the current zone.
//
// The name is the tail of the /etc/localtime symlink target after "zoneinfo/",
// which is how macOS, Linux, NixOS and WSL all record it. The link is replaced,
// not modified, when the zone changes, so the agent watches the directory it
// lives in with libfswatch (FSEvents on macOS, inotify on Linux) and re-reads
// the link and its data whenever anything there changes. Nothing polls.
//
// Usage: timezone-agent -o DIR [-f LINK] [-l SEC] [-d]
//   -o DIR   directory to publish into; the installer's service passes
//            $HOME/.local/share/devcontainer-timezone, which the Feature mounts
//   -f LINK  symlink to follow (/etc/localtime)
//   -l SEC   watcher latency, how long events are batched (0.5)
//   -d       detach and run in the background
// The directory is locked while an instance runs, so a second instance exits 0
// at once and starting the agent from a shell profile is harmless.

#include <fcntl.h>
#include <libfswatch/c++/event.hpp>
#include <libfswatch/c++/libfswatch_exception.hpp>
#include <libfswatch/c++/monitor.hpp>
#include <libfswatch/c++/monitor_factory.hpp>
#include <sys/file.h>
#include <unistd.h>
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <expected>
#include <filesystem>
#include <format>
#include <fstream>
#include <iterator>
#include <memory>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

constexpr auto zone_max = std::size_t{128};

struct options {
		fs::path link = "/etc/localtime";
		fs::path dir;
		double latency = 0.5;
		bool daemon = false;
};

// UTC: Apple's libc++ has no time zone database, and local time would shift under the very changes this agent reports.
auto log(std::string_view message) -> void {
	const auto now = std::chrono::floor<std::chrono::seconds>(std::chrono::system_clock::now());
	std::println(stderr, "{:%FT%TZ} {}", now, message);
}

// errno as text, without the thread-unsafe strerror().
[[nodiscard]] auto errno_message(int err) -> std::string {
	return std::error_code{err, std::generic_category()}.message();
}

auto usage() -> void {
	std::println(stderr, "usage: timezone-agent -o DIR [-f LINK] [-l SEC] [-d]");
}

// Zone name from a path such as /var/db/timezone/zoneinfo/Europe/Berlin.
[[nodiscard]] auto zone_from_path(std::string_view path) -> std::optional<std::string> {
	constexpr auto marker = std::string_view{"/zoneinfo/"};
	const auto pos = path.rfind(marker);
	if (pos == std::string_view::npos) {
		return std::nullopt;
	}
	auto zone = path.substr(pos + marker.size());
	if (zone.starts_with("posix/")) {
		zone.remove_prefix(6);
	}
	const auto allowed = [](unsigned char ch) -> bool {
		return std::isalnum(ch) != 0 || ch == '_' || ch == '+' || ch == '/' || ch == '.' || ch == '-';
	};
	if (zone.empty() || zone.size() >= zone_max || zone.starts_with('.') || zone.ends_with('/') || zone.contains("..") || zone.contains("//") || !std::ranges::all_of(zone, allowed)) {
		return std::nullopt;
	}
	return std::string{zone};
}

// The name of the zone the link points at; empty when it is missing or a plain file.
[[nodiscard]] auto read_zone(const fs::path& link) -> std::string {
	auto ec = std::error_code{};
	const auto target = fs::read_symlink(link, ec);
	if (ec) {
		return {};
	}
	return zone_from_path(target.native()).value_or("");
}

// A whole file, following symlinks; empty when it cannot be read.
[[nodiscard]] auto read_file(const fs::path& path) -> std::string {
	auto in = std::ifstream{path, std::ios::binary};
	return {std::istreambuf_iterator<char>{in}, std::istreambuf_iterator<char>{}};
}

// Replace a file's contents without a window where it is missing or partial.
[[nodiscard]] auto replace_file(const fs::path& path, std::string_view content) -> std::expected<void, std::string> {
	const auto tmp = path.parent_path() / std::format(".{}.tmp", path.filename().string());
	auto out = std::ofstream{tmp, std::ios::binary | std::ios::trunc};
	out.write(content.data(), static_cast<std::streamsize>(content.size()));
	out.close();
	if (out.fail()) {
		return std::unexpected{std::format("cannot write {}", tmp.string())};
	}
	auto ec = std::error_code{};
	fs::permissions(tmp, fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read | fs::perms::others_read, ec);
	fs::rename(tmp, path, ec);
	if (ec) {
		return std::unexpected{std::format("cannot move {} to {}: {}", tmp.string(), path.string(), ec.message())};
	}
	return {};
}

class fd_handle {
	public:
		fd_handle() = default;
		explicit fd_handle(int fd) : fd_{fd} {}
		fd_handle(fd_handle&& other) noexcept : fd_{std::exchange(other.fd_, -1)} {}
		auto operator=(fd_handle&& other) noexcept -> fd_handle& {
			if (this != &other) {
				reset();
				fd_ = std::exchange(other.fd_, -1);
			}
			return *this;
		}
		fd_handle(const fd_handle&) = delete;
		auto operator=(const fd_handle&) -> fd_handle& = delete;
		~fd_handle() { reset(); }

		[[nodiscard]] auto get() const -> int { return fd_; }
		explicit operator bool() const { return fd_ >= 0; }
		auto reset() -> void {
			if (fd_ >= 0) {
				::close(std::exchange(fd_, -1));
			}
		}

	private:
		int fd_ = -1;
};

// Combine POSIX flag macros without signed bitwise arithmetic.
[[nodiscard]] auto with_flag(int value, int flag) -> int {
	return static_cast<int>(static_cast<unsigned>(value) | static_cast<unsigned>(flag));
}

// Fork into the background. The parent process never returns from here; the
// child returns false if detaching failed.
[[nodiscard]] auto daemonize() -> bool {
	const auto pid = ::fork();
	if (pid < 0) {
		std::perror("fork");
		return false;
	}
	if (pid > 0) {
		::_exit(0); // the parent is done
	}
	if (::setsid() < 0) {
		std::perror("setsid");
		return false;
	}
	if (::chdir("/") < 0) {
		std::perror("chdir");
	}
	const auto null = fd_handle{::open("/dev/null", O_RDWR)}; // NOLINT(cppcoreguidelines-pro-type-vararg)
	if (null) {
		::dup2(null.get(), STDIN_FILENO);
		::dup2(null.get(), STDOUT_FILENO);
		if (::isatty(STDERR_FILENO) != 0) { // keep a redirected stderr as the log
			::dup2(null.get(), STDERR_FILENO);
		}
	}
	return true;
}

// Keeps DIR/localtime and DIR/zone in step with the link.
class publisher {
	public:
		explicit publisher(options opts) :
				opts_{std::move(opts)},
				localtime_{opts_.dir / "localtime"},
				zone_{opts_.dir / "zone"},
				published_data_{read_file(localtime_)},
				published_zone_{read_file(zone_)} {}

		// Bring the directory up to date with the link.
		auto publish() -> void {
			auto data = read_file(opts_.link);
			if (data.empty()) {
				log(std::format("cannot read {}; keeping the previous copy", opts_.link.string()));
				return;
			}
			const auto zone = read_zone(opts_.link);
			auto zone_line = zone.empty() ? std::string{} : std::format("{}\n", zone);
			auto changed = false;
			if (data != published_data_ && write(localtime_, data)) {
				published_data_ = std::move(data);
				changed = true;
			}
			if (zone_line != published_zone_ && write(zone_, zone_line)) {
				published_zone_ = std::move(zone_line);
				changed = true;
			}
			if (changed) {
				log(std::format("{} -> {}", opts_.link.string(), zone.empty() ? "(no zone name)" : zone));
			}
		}

	private:
		static auto write(const fs::path& path, std::string_view content) -> bool {
			const auto written = replace_file(path, content);
			if (!written) {
				log(written.error());
			}
			return written.has_value();
		}

		options opts_;
		fs::path localtime_;
		fs::path zone_;
		std::string published_data_;
		std::string published_zone_;
};

auto on_events(const std::vector<fsw::event>& /*events*/, void* context) -> void {
	try {
		static_cast<publisher*>(context)->publish();
	} catch (const std::exception& error) { // never unwind into libfswatch
		log(std::format("cannot publish: {}", error.what()));
	}
}

[[nodiscard]] auto parse_args(std::span<char*> args) -> std::expected<options, std::string> {
	auto opts = options{};
	const auto argc = static_cast<int>(args.size());
	auto opt = 0;
	// NOLINTNEXTLINE(concurrency-mt-unsafe)
	while ((opt = ::getopt(argc, args.data(), ":df:hl:o:")) != -1) {
		switch (opt) {
			case 'd': opts.daemon = true; break;
			case 'f': opts.link = optarg; break;
			case 'h': return std::unexpected{""};
			case 'l':
				opts.latency = std::strtod(optarg, nullptr);
				if (opts.latency <= 0) {
					return std::unexpected{std::format("bad latency: {}", optarg)};
				}
				break;
			case 'o': opts.dir = optarg; break;
			case ':': return std::unexpected{std::format("missing value for -{}", static_cast<char>(optopt))};
			default: return std::unexpected{std::format("unknown option: -{}", static_cast<char>(optopt))};
		}
	}
	if (optind < argc) {
		return std::unexpected{std::format("unexpected argument: {}", *std::next(args.begin(), optind))};
	}
	if (opts.dir.empty()) {
		return std::unexpected{"-o DIR is required"};
	}
	return opts;
}

[[nodiscard]] auto run_agent(const options& opts) -> int {
	auto ec = std::error_code{};
	fs::create_directories(opts.dir, ec);
	if (ec) {
		log(std::format("cannot create {}: {}", opts.dir.string(), ec.message()));
		return 1;
	}
	// One instance per directory; the kernel releases the lock when the process ends.
	const auto lock = fd_handle{::open(opts.dir.c_str(), O_RDONLY)}; // NOLINT(cppcoreguidelines-pro-type-vararg)
	if (!lock) {
		log(std::format("cannot open {}: {}", opts.dir.string(), errno_message(errno)));
		return 1;
	}
	if (::flock(lock.get(), with_flag(LOCK_EX, LOCK_NB)) < 0) {
		if (errno == EWOULDBLOCK) {
			log(std::format("another instance is publishing to {}; nothing to do", opts.dir.string()));
			return 0;
		}
		log(std::format("cannot lock {}: {}", opts.dir.string(), errno_message(errno)));
		return 1;
	}
	// Watch the directory holding the link: the link itself is replaced on a
	// zone change, which a watch on it (which follows it) would never see.
	const auto watched = fs::canonical(opts.link.parent_path(), ec);
	if (ec) {
		log(std::format("cannot resolve the directory of {}: {}", opts.link.string(), ec.message()));
		return 1;
	}
	if (opts.daemon && !daemonize()) {
		return 1;
	}

	auto pub = publisher{opts};
	pub.publish();
	log(std::format("publishing {} to {}; watching {}", opts.link.string(), opts.dir.string(), watched.string()));

	const auto monitor = std::unique_ptr<fsw::monitor>{fsw::monitor_factory::create_monitor(fsw_monitor_type::system_default_monitor_type, {watched.string()}, on_events, &pub)};
	monitor->set_recursive(false);
	monitor->set_follow_symlinks(false);
	monitor->set_latency(opts.latency);
	try {
		monitor->start(); // runs until the process is killed
	} catch (const fsw::libfsw_exception& error) {
		log(std::format("watcher failed: {}", error.what()));
		return 1;
	}
	return 0;
}

auto main(int argc, char** argv) -> int {
	try {
		const auto parsed = parse_args(std::span{argv, static_cast<std::size_t>(argc)});
		if (parsed) {
			return run_agent(*parsed);
		} else {
			if (!parsed.error().empty()) {
				log(parsed.error());
			}
			usage();
			return parsed.error().empty() ? 0 : 2;
		}

	} catch (const std::exception& error) {
		// plain C stdio only: nothing here may throw
		std::fputs("fatal: ", stderr);
		std::fputs(error.what(), stderr);
		std::fputc('\n', stderr);
		return 1;
	} catch (...) {
		std::fputs("fatal: unknown exception\n", stderr);
		return 1;
	}
}
