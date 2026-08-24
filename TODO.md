# VibeVim TODO

Bu liste, VibeVim için istenen davranışların kalıcı takip listesidir. Yeni bir
istek önce buraya eklenir; doğrulanmadan tamamlandı olarak işaretlenmez.

## Kullanım yüzeyi ve düzen

- [x] Açılışta dosya ağacı + merkez editör + sağ Codex alanı.
- [x] F1 kontrol merkezi ve global F1-F8/tema/terminal kısayolları.
- [x] Tüm panellerde mouse ile görünen [X] kapatma yolu.
- [x] Merkez dosya sekmeleri: geniş isim, ikon, görünür X, sağ tık ve orta
      tıkla güvenli kapatma.
- [x] Dosya sekmesine tıklayınca NvimTree/Codex panelini yanlışlıkla
      değiştirmeme.
- [x] Dosya kapatırken değişiklik varsa Kaydet/Kapat/İptal onayı.
- [x] Markdown dosyalarını ayrı önizleme yerine normal merkez editörde açma.
- [x] Yazi/Glimpse medya önizlemesi ve panel kapatma davranışı.
- [ ] Mouse tıklama/odak davranışını farklı terminal emülatörlerinde (iTerm2,
      Ghostty, Konsole) elle doğrulamak.

## Terminal ve agent sekmeleri

- [x] Bağımsız terminali altta split yerine sağda sekmeli açma; tüm Shell/Codex/
      OpenCode/Claude oturumlarını tek ortak terminal penceresinde buffer
      değiştirerek gösterme.
- [x] Sağ terminal şeridinde + Term, Shell/Codex/OpenCode/Claude ve X.
- [x] Birden fazla terminal/agent oturumunu arka planda koruyup hızlı geçiş.
- [x] Yeni terminalde kullanıcının seçtiği komutu çalıştırabilme.
- [x] [+ Term] ile yeni terminal açarken mevcut sağ paneli yeniden kullanma;
      sekme değişiminde pencere sayısını artırmama ve [X] ile yalnızca aktif
      terminal buffer'ını kapatma.
- [x] Codex ana oturumu ve ek Codex agent sekmeleri.
- [ ] Terminal sekmelerinin mevcut aktif terminali kapatmadan yeniden
      başlatma/geri yükleme senaryolarını farklı shell'lerde doğrulamak.

## Codex ve diff

- [x] Codex'in değiştirdiği dosyayı merkez editörde otomatik açma.
- [x] Aynı dosyada eklenen satırları yeşil, silinenleri kırmızı inline gösterme.
- [x] YOLO/full-access modunda diff onay istemini atlama.
- [x] Codex input odak değişimlerini ve otomatik scroll titremesini azaltma.
- [x] Codex yazarken merkez dosya açıldığında input odağını koruma.
- [x] Codex geçmişinde yukarı kaydırınca otomatik aşağı takip etmeyi durdurma;
      en alta dönünce takip modunu yeniden açma.
- [x] Birden fazla diff hunk'ı için merkez sekme şeridinde Yukarı/Aşağı gezinme
      ve CodexDiffAcceptHunk/<leader>da ile hunk kabulü.
- [x] Diff aracında açık tüm Codex sayfalarını (dosyaları) tek seferde kabul
      etme; yeni oluşturulan dosyalar da bu kapsama dahil.
- [x] Kabul edilen hunk'ı oturum içi yeni baseline yapıp tekrar değişene kadar
      yeşil/kırmızı göstermeme.
- [ ] Hunk kabulü/reddinin Codex CLI, CodeCompanion ve manuel edit akışlarında
      ayrı ayrı elle test edilmesi.
- [ ] Diff özeti ve kabul edilen baseline durumunun oturum yeniden açıldığında
      istenen şekilde sıfırlanıp sıfırlanmayacağına karar verilmesi.

## Büyük ve üretilmiş dosyalar

- [x] *.tsbuildinfo, *.map, minified dosyalar, lockfile ve .info metadata
      için hafif görüntüleyici modu.
- [x] Büyük JSON/YAML/lock dosyalarında daha düşük eşik ile Treesitter,
      syntax regex, mini.diff, indentscope, gitsigns ve LSP yükünü kapatma.
- [x] Wrap/fold/cursorline/signcolumn gibi pahalı çizimleri bu dosyalarda
      azaltma.
- [x] Aynı buffer'da normal dosyaya geçerken büyük-dosya ayarlarını temizleme.
- [x] Üretilmiş metadata/bundle dosyalarını (tsbuildinfo, map, minified,
      lock/cache/debug-log ve benzerleri) NvimTree, buffer sekmeleri ve Codex
      otomatik diff akışından gizleme.
- [ ] Gerçek proje boyutlarında açılış süresi ve bellek kullanımını ölçmek;
      gerekirse eşikleri proje ayarı olarak dışarı almak.

## Temalar, ikonlar ve görünüm

- [x] Varsayılan Flexoki Dark.
- [x] Catppuccin, Kanagawa ve Flexoki tema seçimi.
- [x] Tema değişiminde Codex/CodeCompanion input ve terminal renklerini
      yenileme.
- [x] nvim-web-devicons fallback ve mini.icons kurulumu.
- [ ] Nerd Font bulunmayan terminaller için gerçek font/ikon doğrulaması ve
      gerekirse metin fallback'lerinin gözden geçirilmesi.

## Dağıtım ve kalite

- [x] VibeVim adı, lisans, README ve katkı yönergeleri.
- [x] luajit -b, headless Neovim smoke testleri ve git diff --check.
- [ ] Değişiklikleri anlamlı commit ile GitHub main dalına gönderme.
- [ ] Kurulumun npm üzerinden tek komut/tek tık akışına dönüştürülmesi.
- [ ] README'de Türkçe açıklama + varsayılan İngilizce açıklama, ekran
      görüntüsü ve sorun giderme notlarının güncel tutulması.
