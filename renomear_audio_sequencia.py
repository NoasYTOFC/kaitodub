from __future__ import annotations

import re
import uuid
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog


NUMERIC_NAME = re.compile(r"^(\d+)$")


def choose_files() -> list[Path]:
    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    files = filedialog.askopenfilenames(
        title="Selecione os áudios para renomear",
        filetypes=[("Áudios WAV", "*.wav"), ("Todos os arquivos", "*.*")],
    )
    root.destroy()
    return [Path(file) for file in files]


def ask_offset() -> int | None:
    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    offset = simpledialog.askinteger(
        "Alterar sequência",
        "Digite o número para somar aos nomes:\n\n"
        "Exemplo: 2 transforma 0.wav em 2.wav.",
        parent=root,
    )
    root.destroy()
    return offset


def rename_files(files: list[Path], offset: int) -> int:
    entries: list[tuple[Path, Path]] = []
    seen_names: set[str] = set()
    selected_paths = {file.resolve() for file in files}

    for file in files:
        match = NUMERIC_NAME.fullmatch(file.stem)
        if match is None:
            raise ValueError(f"O arquivo '{file.name}' não tem nome numérico.")

        new_number = int(match.group(1)) + offset
        if new_number < 0:
            raise ValueError(
                f"'{file.name}' resultaria em um número negativo ({new_number})."
            )

        target = file.with_name(f"{new_number}{file.suffix}")
        target_key = str(target.resolve()).lower()
        if target_key in seen_names:
            raise ValueError(f"Há mais de um arquivo tentando virar '{target.name}'.")
        seen_names.add(target_key)

        if target.exists() and target.resolve() not in selected_paths:
            raise FileExistsError(
                f"O arquivo de destino já existe e não foi selecionado: '{target.name}'."
            )
        entries.append((file, target))

    temporary_entries: list[tuple[Path, Path]] = []
    for source, target in entries:
        temporary = source.with_name(f".kaitodub_tmp_{uuid.uuid4().hex}{source.suffix}")
        source.rename(temporary)
        temporary_entries.append((temporary, target))

    try:
        for temporary, target in temporary_entries:
            temporary.rename(target)
    except Exception:
        for temporary, target in reversed(temporary_entries):
            if temporary.exists() and not target.exists():
                temporary.rename(target)
        raise

    return len(entries)


def main() -> None:
    files = choose_files()
    if not files:
        return

    offset = ask_offset()
    if offset is None:
        return

    try:
        count = rename_files(files, offset)
    except Exception as error:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror("Não foi possível renomear", str(error), parent=root)
        root.destroy()
        return

    root = tk.Tk()
    root.withdraw()
    messagebox.showinfo(
        "Sequência alterada",
        f"{count} arquivo(s) renomeado(s) com deslocamento {offset:+d}.",
        parent=root,
    )
    root.destroy()


if __name__ == "__main__":
    main()
