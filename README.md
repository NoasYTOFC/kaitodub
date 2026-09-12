# KaitoDub

Aplicativo Flutter para organizar sessões de dublagem de áudio em massa, principalmente para jogos.

## Recursos

- Importação de vários arquivos de áudio e arquivos ZIP para uma pasta nomeada.
- Reprodução do áudio original e seleção do microfone.
- Gravação de dublagens com duração baseada no áudio original.
- Waveforms do áudio original e da gravação.
- Normalização automática de loudness no Windows e Linux para preparar a dublagem para uso no jogo.
- Confirmação individual das dublagens e exportação da sessão em ZIP.
- Persistência local das sessões e dos arquivos importados.

## Plataformas

O fluxo principal foi validado no Windows. A gravação usa o pacote `record`, com implementação nativa para Windows. A pós-produção com FFmpeg é aplicada apenas no Windows e Linux; no Android e iOS a gravação não passa por essa etapa.

## Como executar

Requisitos:

- Flutter 3.38 ou superior.
- Dart 3.10 ou superior.
- Windows 10/11 para executar a versão Windows.

```bash
flutter pub get
flutter run -d windows
```

Para validar a versão Windows:

```bash
flutter analyze lib/main.dart
flutter build windows --debug
```

## Fluxo de uso

1. Importe vários áudios ou um ZIP contendo os áudios originais.
2. Dê um nome à pasta criada para organizar os arquivos do personagem.
3. Abra a pasta e selecione o microfone do Windows.
4. Grave cada dublagem usando o temporizador opcional.
4. Reproduza e confirme as gravações.
5. Exporte a sessão para um novo arquivo ZIP.

Os arquivos de sessão ficam armazenados no diretório de dados do aplicativo. O áudio exportado como dublagem é salvo em WAV mono PCM, com loudness normalizado no desktop.
