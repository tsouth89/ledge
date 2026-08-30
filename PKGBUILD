# Maintainer: Brandon South <tsouth2@gmail.com>
pkgname=ledge
pkgver=0.1.0
pkgrel=1
pkgdesc="Sticky notes that live on the edge of the screen, for Hyprland"
arch=('any')
url="https://github.com/tsouth89/ledge"
license=('MIT')
depends=('quickshell' 'qt6-declarative' 'bash')
optdepends=('ttf-jetbrains-mono-nerd: default note font')
# Fetched by tag rather than as a release tarball. This PKGBUILD lives in the
# same repository it packages, so pinning a tarball checksum here is circular:
# writing the sum changes the tarball it is the sum of.
makedepends=('git')
source=("$pkgname::git+$url.git#tag=v$pkgver")
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname"
  install -Dm755 bin/ledge "$pkgdir/usr/bin/ledge"
  install -Dm644 systemd/ledge.service "$pkgdir/usr/lib/systemd/user/ledge.service"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 docs/config.md "$pkgdir/usr/share/doc/$pkgname/config.md"
  install -Dm644 docs/hyprland.md "$pkgdir/usr/share/doc/$pkgname/hyprland.md"
  install -Dm644 ledge.desktop "$pkgdir/usr/share/applications/ledge.desktop"
  install -Dm644 assets/ledge.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/ledge.svg"

  # The whole shell tree, not a list of extensions. Filtering by extension
  # silently dropped Core/Markup.js, which every note imports, so the packaged
  # app failed to load while the source tree ran fine.
  install -dm755 "$pkgdir/usr/share/$pkgname"
  cp -r shell "$pkgdir/usr/share/$pkgname/"
  find "$pkgdir/usr/share/$pkgname" -type d -exec chmod 755 {} +
  find "$pkgdir/usr/share/$pkgname" -type f -exec chmod 644 {} +
}
