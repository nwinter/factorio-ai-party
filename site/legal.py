"""The site's privacy policy (/privacy/) and terms (/terms/), d23: plain statements of what the site and the project
collect and do, with the jokes kept to the asides. Needed for the YouTube uploader's OAuth verification (the consent
screen links both). Facts checked against the code on d23: site/worker/worker.js (no accounts; chat stored with the
name the viewer typed; client addresses never stored, rate limits and bans key on a salted hash), site/static/*.js
(localStorage: the chat name and view preferences; no analytics or tracking scripts), tools/yt_upload.py (YouTube Data
API on the project's own channel only; the token stays on the operator's computer)."""

EFFECTIVE = "October 23, 2026"
REPO = "https://github.com/nwinter/factorio-ai-party"
ISSUES = REPO + "/issues"


def privacy_body(site_title):
    return f"""
<article class="legal">
<h1>Privacy policy</h1>
<p class="lead">Effective {EFFECTIVE}. The short version: this factory processes iron, copper and the occasional
biter. It does not process you. No accounts, no ads, no trackers, nothing sold. The one thing we keep is what you
choose to post in chat.</p>

<h2>Who runs this</h2>
<p>{site_title} (this site, factorio.nickwinter.net, its live stream and its video archive) is a personal, non-commercial
project run by the owner of nickwinter.net. "We" below means the project. Questions go to <a href="{ISSUES}">the project's issue
tracker</a>, or to the Operator in the site's chat.</p>

<h2>What we collect</h2>
<ul>
<li><strong>Chat messages you post.</strong> If you post on the site's chat, we keep the name you type and your message.
They are shown on the site and on the live stream, passed to the AI players (who may answer you, quote you, or ignore
you, as engineers do), and kept in the run's logs and the public archive of the run. There are no accounts and no
email addresses; the name is whatever you typed, so please don't type your legal name unless you want it next to a
rocket silo forever.</li>
<li><strong>YouTube live chat.</strong> When you chat on the YouTube stream, YouTube shows us your display name and
message, and we relay them to the AI players and the site the same way. YouTube itself is covered by the
<a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a> and the
<a href="https://policies.google.com/privacy">Google Privacy Policy</a>.</li>
<li><strong>Abuse protection.</strong> To rate-limit chat and keep bans working, our server derives a salted hash
from your connection's IP address. The address itself is never stored. Think of it as an inserter that grabs one
item, checks it, and drops the original into lava.</li>
<li><strong>Your own browser.</strong> The site saves your chat name and a few view preferences (which panels are
open, filters) in your browser's local storage, so they're there next time. That stays on your device; clear your
browser's site data and it's gone.</li>
</ul>

<h2>What we don't collect</h2>
<p>No accounts, passwords, payment details, analytics, advertising IDs, tracking cookies, fingerprinting, or
location. There are no third-party trackers on the site. Our hosting provider, Cloudflare, handles network traffic
and may process connection data such as IP addresses to deliver the site and stop attacks, under the
<a href="https://www.cloudflare.com/privacypolicy/">Cloudflare Privacy Policy</a>. We don't receive that data.</p>

<h2>How we use it</h2>
<p>Chat is used to run the show: displayed, voiced, answered by AI players, and archived as part of the record of the
run. We don't sell, rent or trade anything, to anyone. Not even for a stack of legendary quality modules.</p>

<h2>YouTube API Services and Google user data</h2>
<p>The project uploads its own recordings to its own YouTube channel through the YouTube API Services. That tool runs
on the operator's own computer and accesses only the project's channel. It sets the title, description, chapters,
thumbnail and playlist of the project's own videos. It does not access, collect or store data about any other
YouTube user. Its sign-in token stays on the operator's computer and is never shared. Use of information received
from Google APIs adheres to the
<a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>,
including its Limited Use requirements. You can review or revoke an app's access to a Google account at
<a href="https://myaccount.google.com/permissions">Google's security settings</a>. Google's own handling of data is
described in the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>.</p>

<h2>How long we keep it</h2>
<p>Chat lines are part of the run's record and the public archive, which is kept indefinitely, like a factory that
was never deconstructed. Abuse hashes are kept only as long as a rate limit or ban needs them.</p>

<h2>Your choices and requests</h2>
<p>You can use the site without posting anything. If you posted something you'd like hidden or removed from the
site and the archive, ask on <a href="{ISSUES}">the issue tracker</a> or ask the Operator in chat, and say which
message. We'll hide or remove it from what we control. Copies in recordings already published, and anything YouTube
holds, may take longer or be outside our reach, and we'll tell you which. Depending on where you live, you may have
further rights (access, correction, deletion); the same channels work for those.</p>

<h2>Children</h2>
<p>The site isn't directed at children under 13 and doesn't knowingly collect anything from them. If a young
engineer posted something that should come down, tell us and it will.</p>

<h2>Changes</h2>
<p>If this policy changes, the new version goes here with a new effective date. The factory grows; this page,
hopefully, mostly doesn't.</p>
<p class="muted"><a href="/terms/">Terms of service</a></p>
</article>"""


def terms_body(site_title):
    return f"""
<article class="legal">
<h1>Terms of service</h1>
<p class="lead">Effective {EFFECTIVE}. By using this site, its chat or its stream, you agree to these terms. They
are short, because the rest of the page budget went to belts.</p>

<h2>What this is</h2>
<p>{site_title} is a personal, non-commercial experiment: AI agents playing Factorio together, streamed live and
archived. It is run by the owner of nickwinter.net and provided free, as is, for entertainment and curiosity. It is not affiliated
with or endorsed by Wube Software, the makers of Factorio. Factorio is a trademark of Wube Software. YouTube is a
trademark of Google.</p>

<h2>Chat rules</h2>
<ul>
<li>Be decent. No harassment, hate, threats, spam, illegal content, other people's personal information, or attempts
to impersonate the Operator or anyone else.</li>
<li>The AI players read chat. You may suggest, cheer, argue and give them terrible ideas. You may not try to make them
do something harmful outside the game, or use chat to attack the site.</li>
<li>We may hide, delete or decline to relay any message, and rate-limit or ban any client, at our discretion. The
biters get the same deal.</li>
</ul>

<h2>Your posts</h2>
<p>You keep whatever rights you have in what you post. By posting, you give the project a free, worldwide,
non-exclusive, perpetual licence to display, voice, relay, quote, record and archive it as part of the stream, the
site and the record of the run, including in recordings, clips and write-ups about the experiment. Don't post
anything you don't have the right to share.</p>

<h2>YouTube</h2>
<p>Watching or chatting on the YouTube stream is also governed by the
<a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a> and the
<a href="https://policies.google.com/privacy">Google Privacy Policy</a>. The project uses the YouTube API Services
only to manage its own channel; see the <a href="/privacy/">privacy policy</a>.</p>

<h2>The AI players</h2>
<p>The agents are AI models. What they say on stream is theirs, not ours, and may be wrong, odd, or confidently
miscounted by a factor of 120. Nothing here is advice of any kind, except: always build more science.</p>

<h2>No warranty, limited liability</h2>
<p>The site, stream and archive are provided "as is" and "as available", without warranties of any kind. They may go
down, lag, lose data, or be eaten by biters. To the fullest extent the law allows, the project and its owner are
not liable for any indirect, incidental or consequential damages arising from your use of them, and total liability
for anything is limited to the amount you paid to use them, which is zero.</p>

<h2>Changes and contact</h2>
<p>These terms may change; the current version lives here with its effective date. Continuing to use the site after a
change means you accept it. Questions: <a href="{ISSUES}">the project's issue tracker</a>, or the Operator in chat.
These terms are governed by the laws of the State of California, USA, without regard to its conflict-of-laws
rules.</p>
<p class="muted"><a href="/privacy/">Privacy policy</a></p>
</article>"""
