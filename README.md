# KaitoDub

Aplicativo Flutter para organizar sessões de dublagem de áudio em massa, principalmente para jogos.

## Recursos

- Importação de vários arquivos de áudio e arquivos ZIP para uma pasta nomeada.
- Marcação opcional de áudios com dois personagens, com escolha de parte 1, parte 2 ou ambas durante a gravação.
- Reprodução do áudio original e seleção do microfone.
- Gravação de dublagens com duração baseada no áudio original.
- Waveforms do áudio original e da gravação.
- Normalização automática de loudness no Windows e Linux para preparar a dublagem para uso no jogo.
- Confirmação individual das dublagens e exportação da sessão em ZIP.
- Mesclagem de dois ZIPs: partes 1 e 2 são concatenadas com 200 ms de intervalo, e arquivos marcados como ambas são mixados simultaneamente.
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

1. Importe vários arquivos de áudio ou ZIPs.
2. Dê um nome à pasta e, se necessário, marque **2 personagens em um?**.
3. Abra a pasta para ver cada arquivo separadamente.
4. Em uma pasta habilitada para dois personagens, marque a caixinha no áudio, selecione parte 1, parte 2 ou ambas, e grave.
5. Reproduza e confirme as gravações. A exportação inclui `_p1`, `_p2` ou `_both` no nome desses áudios.
6. Para combinar duas partes, use **Mesclar** na tela inicial e selecione o ZIP base e o ZIP de adições. Partes 1 e 2 viram um WAV com 200 ms de intervalo e o silêncio inicial da parte 2 removido; arquivos `_both` presentes nos dois ZIPs são mixados. O ZIP final mantém `_dubbed` e remove o marcador da parte.

Os arquivos de sessão ficam armazenados no diretório de dados do aplicativo. O áudio exportado como dublagem é salvo em WAV mono PCM, com loudness normalizado no desktop.
