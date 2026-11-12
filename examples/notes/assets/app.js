// The Notes page: lists what Zig has stored, and calls Zig to change it.
//
// The bridge is injected by MyZig before this file runs. `myzig.call` returns a
// promise; `myzig.on` subscribes to events the Zig side emits.

const list = document.getElementById('list');
const count = document.getElementById('count');
const empty = document.getElementById('empty');
const saved = document.getElementById('saved');
const form = document.getElementById('composer');
const titleInput = document.getElementById('title');
const bodyInput = document.getElementById('body');

/// Zig stores a note as `[title, body, id]`, because that is also the file
/// format. The page names the fields once, here, so the rest of the code reads
/// `note.title` rather than `note[0]`.
function fromWire(raw) {
  return raw.map(([title, body, id]) => ({ title, body, id }));
}

function render(notes) {
  list.textContent = '';
  count.textContent = notes.length === 1 ? '1 note' : `${notes.length} notes`;
  empty.hidden = notes.length > 0;

  for (const note of notes) {
    const li = document.createElement('li');

    const text = document.createElement('div');
    text.className = 'text';
    const title = document.createElement('div');
    title.className = 'title';
    title.textContent = note.title;
    const body = document.createElement('div');
    body.className = 'body';
    body.textContent = note.body;
    text.append(title, body);

    const remove = document.createElement('button');
    remove.textContent = 'Delete';
    remove.setAttribute('aria-label', `Delete ${note.title}`);
    remove.addEventListener('click', async () => {
      await myzig.call('Notes.delete', String(note.id));
    });

    li.append(text, remove);
    list.append(li);
  }
}

/// Replaces the list from Zig. Called on load and whenever Zig says the notes
/// changed, so a change made from the menu appears here too.
async function refresh() {
  const notes = fromWire(await myzig.call('Notes.list'));
  render(notes);
  saved.textContent = 'Saved';
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  saved.textContent = 'Saving…';
  console.log('composer submitted:', JSON.stringify(titleInput.value));
  try {
    const id = await myzig.call('Notes.add', titleInput.value, bodyInput.value);
    console.log('added note id', id);
  } catch (e) {
    // A failure here was invisible before: the form cleared itself and the
    // user saw nothing happen.
    console.error('add failed', e);
    saved.textContent = 'Could not add the note';
    return;
  }
  titleInput.value = '';
  bodyInput.value = '';
  titleInput.focus();
});

document.getElementById('clear').addEventListener('click', () => {
  titleInput.value = '';
  bodyInput.value = '';
  titleInput.focus();
});

// A scripted self-test: add one note through the same call the form makes.
// The page asks for it rather than waiting for an event, because an event sent
// before this script ran would be missed — the framework has no queue for a
// listener that arrives late, and pretending otherwise would hide a real gap.
const params = new URLSearchParams(location.search);

if (params.get('selftest') === 'delete') {
  // Delete every note through the same call the Delete button makes, so the
  // removal path is checkable without a pointer.
  myzig.call('Notes.list').then((raw) => {
    const notes = fromWire(raw);
    console.log('deleting', notes.length, 'notes');
    return Promise.all(notes.map((n) => myzig.call('Notes.delete', String(n.id))));
  }).then(() => console.log('delete self test done'))
    .catch((e) => console.error('delete selftest failed', e));
}

if (params.get('selftest') === 'menu') {
  // Nothing to do here: the Zig side reacts to the menu event itself.
  console.log('ready for a menu command');
}

if (params.get('selftest') === '1') {
  myzig.call('Notes.add', 'Self test', 'Added without a pointer.')
    .then((id) => console.log('selftest added note', id))
    .catch((e) => console.error('selftest failed', e));
}

// Zig emits this whenever the note list changes, whoever changed it.
myzig.on('notes:changed', () => {
  refresh().catch((e) => {
    saved.textContent = 'Could not read the notes';
    console.error('notes:changed refresh failed', e);
  });
});

// The Zig side resets the form after a note was made from the menu.
myzig.on('notes:form', () => {
  titleInput.value = '';
  bodyInput.value = '';
  titleInput.focus();
});

refresh().catch((e) => {
  saved.textContent = 'Could not read the notes';
  console.error('initial load failed', e);
});
