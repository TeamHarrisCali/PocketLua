# Discord on the Cardputer

The Discord app reads and writes one channel through **your own bot**. A bot
account is what Discord's API is for. Automating your personal account (a
"self-bot") is against Discord's terms and can get the account banned, so the
app never does that.

## One-time setup (on a PC)

1. Go to <https://discord.com/developers/applications> and click **New Application**. Give it a name.
2. Open **Bot**:
   - **Reset Token** and copy the token. Treat it like a password.
   - Under **Privileged Gateway Intents**, turn on **Message Content Intent**. Without it, the bot
     sees other people's messages as empty.
3. Open **OAuth2 > URL Generator**:
   - Tick **bot**, then the permissions **View Channels**, **Send Messages** and
     **Read Message History**.
   - Open the generated link and add the bot to your server. Use a server you own: a small
     private one is best.
4. With the Cardputer's SD card in the PC, create `/liveos/data/discord.txt` containing:

   ```
   token=YOUR_BOT_TOKEN
   ```

## Using it

- Open **Discord** (in the Net folder) with Wi-Fi on.
- Pick the server, then the channel. The app remembers the channel and reopens there.
- **Messages:** type and press Enter to send. Fn+; and Fn+. scroll back through the last 30 messages.
  Your bot's own messages start with `>`.
- **Keys:** Esc goes back to the channel list. Fn+H lists all the keys.
- **Updates:** the app checks for new messages every 4 seconds while it is open, and stops when you
  leave.

## Notes

- **Text:** it is shown as plain ASCII, because the screen font has no accents or emoji. Accented
  letters lose their accents and emoji become `?`.
- **Memory:** each request is an encrypted (HTTPS) connection to discord.com, checked against Google
  Trust Services' root certificates. It uses BearSSL, which needs one 16.7 KB buffer (set aside when the
  app opens) and about 6 KB of fixed state. The connection needs the clock, so wait a moment after
  Wi-Fi connects. If it fails, the device log says why (`python3 tools/monitor.py`).
- **The token:** it stays on the SD card and in native code; apps never see it. If the card is lost,
  reset the token in the developer portal.
