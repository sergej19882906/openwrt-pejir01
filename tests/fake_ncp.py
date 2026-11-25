#!/usr/bin/env python3
"""Эмулятор модуля EFR32 (NCP) + Gecko-загрузчика для теста pejir-ncp-flash.

Работает на паре PTY: slave-конец отдаётся утилите pejir-ncp-flash
(например, как /dev/umxtty1), master-конец обслуживает этот скрипт.

Эмулируются:
  * EZSP: RST-кадр -> RSTACK, кадр конфигурации версии -> ответ v8, ACK;
  * launchStandaloneBootloader -> переход в режим загрузчика;
  * Gecko Bootloader: баннер, меню, '1' -> режим XMODEM, приём образа
    по XMODEM-CRC с проверкой CRC каждого блока;
  * '2' -> перезапуск NCP в приложение.

Принимаемые аргументы:
  --pty       записать путь slave-конца в этот файл (его ждёт утилита)
  --out       сохранить принятый образ в этот файл
  --silent    не отвечать по EZSP (модуль не NCP)
  --no-xmodem не переходить в режим XMODEM (загрузчик не готов)
"""

import argparse
import os
import struct
import sys
import time

RST = bytes([0x1A, 0xC0, 0x38, 0xBC, 0x7E])
RSTACK = bytes([0x1A, 0xC1, 0x02, 0x0B, 0x0A, 0x52, 0x7E])
ACK = bytes([0x81, 0x60, 0x59, 0x7E])
LAUNCH_BL = bytes([0x7D, 0x31, 0x43, 0x21, 0x27, 0x55, 0x6E, 0x90, 0x7E])
V8_RESP = bytes([0x01, 0x42, 0xA1, 0xA8, 0x5C, 0x28, 0x25, 0xD5, 0x30, 0x86, 0x7E])

XMODEM_SOH = 0x01
XMODEM_EOT = 0x04
XMODEM_ACK = 0x06
XMODEM_NAK = 0x15


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class Fake:
    def __init__(self, fd, silent=False, no_xmodem=False):
        self.fd = fd
        self.silent = silent
        self.no_xmodem = no_xmodem
        self.image = bytearray()
        self.blocks = 0
        self.bad_crc = 0
        self.saw_run = False
        self.ezsp_ok = False

    def write(self, data: bytes):
        os.write(self.fd, data)

    def read(self, n: int, timeout=15.0) -> bytes:
        """Читает n байт. Терпит закрытие slave-конца: утилита переоткрывает
        порт после launchStandaloneBootloader, и в этот момент master видит
        EOF - надо просто ждать следующего открытия."""
        out = bytearray()
        end = time.time() + timeout
        while len(out) < n:
            remaining = end - time.time()
            if remaining <= 0:
                break
            import select
            r, _, _ = select.select([self.fd], [], [], remaining)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, n - len(out))
            except OSError:
                chunk = b""
            if not chunk:
                # slave закрыт - ждём, пока утилита откроет порт заново
                time.sleep(0.05)
                continue
            out += chunk
        return bytes(out)

    def run(self):
        # --- фаза EZSP ---
        while True:
            data = self.read(5)
            if len(data) < 5:
                return
            if data == RST:
                if self.silent:
                    continue
                self.write(RSTACK)
                cfg = self.read(8)
                if len(cfg) < 8:
                    return
                self.write(V8_RESP)
                self.read(len(ACK))  # ACK от утилиты
                self.ezsp_ok = True
            elif data == LAUNCH_BL[:5]:
                rest = self.read(4)
                if len(rest) < 4:
                    return
                # переход в загрузчик
                self.bootloader()
                return
            else:
                # неожиданные байты - продолжаем ждать RST
                continue

    def bootloader(self):
        time.sleep(0.2)
        # приглашение: утилита шлёт "\n"
        self.read(1, timeout=30)
        self.write(b"\r\nGecko Bootloader v1.8.4\r\n")
        self.write(b"1. upload gbl\r\n2. run\r\n3. gbl info\r\n")
        # ждём команду меню
        cmd = self.read(1, timeout=30)
        if cmd != b"1":
            return
        self.write(b"BL > 1\r\nbegin upload\r\n")
        if self.no_xmodem:
            return
        self.write(b"C")

        while True:
            head = self.read(1, timeout=20)
            if not head:
                return
            if head[0] == XMODEM_EOT:
                self.write(bytes([XMODEM_ACK]))
                break
            if head[0] != XMODEM_SOH:
                continue
            body = self.read(132, timeout=20)
            if len(body) < 132:
                return
            seq = body[0]
            inv = body[1]
            data = body[2:130]
            crc = struct.unpack(">H", body[130:132])[0]
            if (seq ^ inv) != 0xFF or crc16_xmodem(data) != crc:
                self.bad_crc += 1
                self.write(bytes([XMODEM_NAK]))
                continue
            self.image += data
            self.blocks += 1
            self.write(bytes([XMODEM_ACK]))

        # '2' - запуск приложения
        cmd = self.read(1, timeout=30)
        if cmd == b"2":
            self.saw_run = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pty")
    ap.add_argument("--out")
    ap.add_argument("--silent", action="store_true")
    ap.add_argument("--no-xmodem", action="store_true")
    args = ap.parse_args()

    master, slave = os.openpty()
    slave_name = os.ttyname(slave)
    if args.pty:
        with open(args.pty, "w") as f:
            f.write(slave_name + "\n")

    fake = Fake(master, silent=args.silent, no_xmodem=args.no_xmodem)
    try:
        fake.run()
    finally:
        if args.out:
            with open(args.out, "wb") as f:
                f.write(fake.image)
        summary = (
            f"ezsp_ok={int(fake.ezsp_ok)} blocks={fake.blocks} "
            f"bytes={len(fake.image)} bad_crc={fake.bad_crc} run={int(fake.saw_run)}"
        )
        with open(args.out + ".summary", "w") as f:
            f.write(summary + "\n")
        sys.stderr.write(summary + "\n")
        os.close(master)


if __name__ == "__main__":
    main()
