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
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname-$pkgver"
  install -Dm755 bin/ledge "$pkgdir/usr/bin/ledge"
  install -Dm644 systemd/ledge.service "$pkgdir/usr/lib/systemd/user/ledge.service"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 docs/config.md "$pkgdir/usr/share/doc/$pkgname/config.md"

  find shell -type f \( -name '*.qml' -o -name 'qmldir' \) -exec \
    install -Dm644 {} "$pkgdir/usr/share/$pkgname/{}" \;
}
