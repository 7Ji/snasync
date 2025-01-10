all:
install:
	install -Dm755 snasync.sh "${DESTDIR}/usr/bin/snasync"
ifeq (${INTEGRATION},systemd)
install: install-systemd
endif
install-systemd:
	install -Dm644 systemd/snasync.service "${DESTDIR}/usr/lib/systemd/system/snasync.service"
	install -Dm644 systemd/snasync.timer "${DESTDIR}/usr/lib/systemd/system/snasync.timer"
	install -Dm644 systemd/snasync.conf "${DESTDIR}/etc/conf.d/snasync"

.PHONY: all install install-systemd
