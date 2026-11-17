// A tester owns the report. The form only produces a local download.
const copy = {
  ru: {
    open: 'Отзыв', title: 'Как прошла ваша история?', close: 'Закрыть',
    note: 'Игра на паузе. Ответы можно скачать файлом и передать организатору теста.',
    situation: 'Через полторы минуты игры что происходило и чего добивались жители?',
    cause: 'Какое событие вы заметили? Что привело к нему и где вы нашли объяснение?',
    ending: 'Чем закончилась история или в какой момент вы остановились?',
    problem: 'Что было трудно увидеть, понять или сделать? Как это повторить?',
    download: 'Скачать отзыв', empty: 'Заполните хотя бы одно поле.', saved: 'Файл отзыва готов.'
  },
  en: {
    open: 'Feedback', title: 'How did your story go?', close: 'Close',
    note: 'The game is paused. Download your answers to share them with the playtest organizer.',
    situation: 'After ninety seconds, what was happening and what were the residents trying to do?',
    cause: 'Which event caught your eye? What caused it and where did you find the explanation?',
    ending: 'How did the story end, or at what point did you stop?',
    problem: 'What was difficult to see, understand or do? How can we reproduce it?',
    download: 'Download feedback', empty: 'Fill in at least one answer.', saved: 'Your feedback file is ready.'
  }
};

export function installPlaytest(openButton, pause) {
  const dialog = document.querySelector('#playtest');
  const form = dialog.querySelector('form');
  const message = dialog.querySelector('[role="status"]');
  let context = {version: '', map: '', mode: '', language: 'ru'};
  let draftContext;
  let downloaded = false;
  let language = '';

  function update(version, map, mode, locale) {
    context = {version, map, mode, language: locale === 'en' ? 'en' : 'ru'};
    if (language === context.language) return;
    language = context.language;
    openButton.textContent = copy[language].open;
    for (const label of dialog.querySelectorAll('[data-copy]')) {
      label.textContent = copy[language][label.dataset.copy];
    }
  }

  update('', '', '', 'ru');
  openButton.onclick = () => {
    pause();
    if (downloaded && draftContext && (draftContext.map !== context.map || draftContext.mode !== context.mode || draftContext.version !== context.version)) {
      form.reset();
      draftContext = null;
      downloaded = false;
    }
    if (!draftContext) draftContext = {...context};
    message.textContent = '';
    dialog.showModal();
  };
  dialog.querySelector('[data-close]').onclick = () => dialog.close();
  form.oninput = () => { downloaded = false; };
  dialog.onclose = () => {
    if (![...new FormData(form).values()].some(value => value.trim())) draftContext = null;
    openButton.focus();
  };
  form.onsubmit = event => {
    event.preventDefault();
    const answers = Object.fromEntries([...new FormData(form)].map(([name, value]) => [name, value.trim()]));
    if (!Object.values(answers).some(Boolean)) {
      message.textContent = copy[language].empty;
      return;
    }
    const report = {schema: 1, game: draftContext, answers};
    const blob = new Blob([JSON.stringify(report, null, 2)], {type: 'application/json'});
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'AI-Sims-playtest.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
    downloaded = true;
    message.textContent = copy[language].saved;
  };
  return update;
}
