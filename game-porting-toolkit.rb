# Copyright (C) 2023 Apple, Inc.
# 
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
# 
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
# 
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

# The 22.1.1 tarball contains an empty sources/freetype directory, which confuses the default CurlDownloadStrategy.
# A custom strategy also allows us to restrict extraction to just the wine subdirectory.
class TarballDownloadStrategy < CurlDownloadStrategy
  def stage(&block)
    ohai "Staging #{cached_location} in #{pwd}"
    system "tar", "-xf", cached_location, "--include=sources/wine/*", "--strip-components=1"
    yield if block_given?
  end
end

class GamePortingToolkit < Formula
  version "1.0.4"
  desc "Apple Game Porting Toolkit"
  homepage "https://developer.apple.com/"
  url "https://media.codeweavers.com/pub/crossover/source/crossover-sources-22.1.1.tar.gz", using: TarballDownloadStrategy
  sha256 "cdfe282ce33788bd4f969c8bfb1d3e2de060eb6c296fa1c3cdf4e4690b8b1831"
  patch :DATA

  depends_on arch: :x86_64
  depends_on "game-porting-toolkit-compiler"
  depends_on "bison" => :build
  uses_from_macos "flex" => :build
  depends_on "mingw-w64" => :build
  depends_on "gstreamer"
  depends_on "pkg-config" # to find the rest of the runtime dependencies

  @@named_deps = ["zlib", # must be explicitly added to PKG_CONFIG_PATH
                  "freetype",
                  "sdl2",
                  "libgphoto2",
                  "faudio",
                  "jpeg",
                  "libpng",
                  "mpg123",
                  "libtiff",
                  "libgsm",
                  "glib",
                  "gnutls",
                  "libusb",
                  "gettext",
                  "openssl@1.1",
                  "sane-backends"]
  @@named_deps.each do |dep|
    depends_on dep
  end

  def install
    # Bypass the Homebrew shims to build native binaries with the dedicated compiler.
    # (PE binaries will be built with mingw32-gcc.)
    compiler = Formula["game-porting-toolkit-compiler"]
    compiler_options = ["CC=#{compiler.bin}/clang",
                        "CXX=#{compiler.bin}/clang++"]

    # Becuase we are bypassing the Homebrew shims, we need to make the dependencies’ headers visible.
    # (mingw32-gcc will automatically make the mingw-w64 headers visible.)
    @@named_deps.each do |dep|
      formula = Formula[dep]
      ENV.append_to_cflags "-I#{formula.include}"
      ENV.append "LDFLAGS", "-L#{formula.lib}"
    end

    # Glib & GStreamer have also has a non-standard include path
    ENV.append "GSTREAMER_CFLAGS", "-I#{Formula['gstreamer'].include}/gstreamer-1.0"
    ENV.append "GSTREAMER_LIBS", "-L#{Formula['gstreamer'].lib}"
    ENV.append "GSTREAMER_CFLAGS", "-I#{Formula['glib'].include}/glib-2.0"
    ENV.append "GSTREAMER_CFLAGS", "-I#{Formula['glib'].lib}/glib-2.0/include"
    ENV.append "GSTREAMER_LIBS", "-lglib-2.0 -lgmodule-2.0 -lgstreamer-1.0 -lgstaudio-1.0 -lgstvideo-1.0 -lgstgl-1.0 -lgobject-2.0"

    # We also need to tell the linker to add Homebrew to the rpath stack.
    ENV.append "LDFLAGS", "-lSystem -L#{HOMEBREW_PREFIX}/lib -Wl,-rpath,@executable_path/../lib,-rpath,#{HOMEBREW_PREFIX}/lib -Wl,-rpath,@executable_path/../lib/external"

    # Common compiler flags for both Mach-O and PE binaries.
    ENV.append_to_cflags "-O3 -Wno-implicit-function-declaration -Wno-format -Wno-deprecated-declarations -Wno-incompatible-pointer-types"
    # Use an older deployment target to avoid new dyld behaviors.
    # The custom compiler is too old to accept "13.0", so we use "10.14".
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "10.14"

    wine_configure_options = ["--prefix=#{prefix}",
                              "--disable-win16",
                              "--disable-tests",
                              "--without-x",
                              "--without-pulse",
                              "--without-dbus",
                              "--without-inotify",
                              "--without-alsa",
                              "--without-capi",
                              "--without-oss",
                              "--without-udev",
                              "--without-krb5"]

    wine64_configure_options = ["--enable-win64",
                                "--with-gnutls",
                                "--with-freetype",
                                "--with-gstreamer"]

    wine32_configure_options = ["--enable-win32on64",
                                "--with-wine64=../wine64-build",
                                "--without-gstreamer",
                                "--without-gphoto",
                                "--without-sane",
                                "--without-krb5",
                                "--disable-winedbg",
                                "--without-vulkan",
                                "--disable-vulkan_1",
                                "--disable-winevulkan",
                                "--without-openal",
                                "--without-unwind",
                                "--without-usb"]

    # Build 64-bit Wine first.
    mkdir buildpath/"wine64-build" do
      system buildpath/"wine/configure", *wine_configure_options, *wine64_configure_options, *compiler_options
      system "make"
    end

    # Now build 32-on-64 Wine.
    mkdir buildpath/"wine32-build" do
      system buildpath/"wine/configure", *wine_configure_options, *wine32_configure_options, *compiler_options
      system "make"
    end

    # Install both builds.
    cd "wine64-build" do
      system "make", "install"
    end

    cd "wine32-build" do
      system "make", "install"
    end
  end

  def post_install
     #Homebrew replaces wine's rpath names with absolute paths, we need to change them back to @rpath relative paths. 
     #Wine relies on @rpath names to cause dlopen to always return the first dylib with that name loaded into the process rather than the actual dylib found using rpath lookup.
     Dir["#{lib}/wine/{x86_64-unix,x86_32on64-unix}/*.so"].each do |dylib|
       chmod 0664, dylib
       MachO::Tools.change_dylib_id(dylib, "@rpath/#{File.basename(dylib)}")
       MachO.codesign!(dylib)
       chmod 0444, dylib
     end
   end

  def caveats
    return unless latest_version_installed?
    "Please follow the instructions in the Game Porting Toolkit README to complete installation."
  end

  test do
    system bin/"wine64", "--version"
  end
end

__END__
