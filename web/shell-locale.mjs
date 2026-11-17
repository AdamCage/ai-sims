const english = {
  'Сохранения на этом устройстве':'Saves are stored on this device',
  'Сохранения восстановлены':'Saves restored',
  'Не удалось записать копию. Прежние сохранения сохранены':'The backup could not be written. Your existing saves are safe.',
  'Не удалось сохранить идентификатор квитанции':'Could not store the billing receipt ID',
  'Мало места · сделайте копию':'Storage is nearly full · download a backup',
  'Фотоархив достиг 512 МБ. Скачайте копию для переноса в новый профиль.':'The photo archive has reached 512 MB. Download a backup to move it to a new profile.',
  'Ошибка сохранения · сделайте копию':'Save error · download a backup',
  'Не удалось сохранить игру перед подключением':'Could not save the game before connecting',
  'Сохранения и фотографии скачаны':'Saves and photos downloaded',
  'Не удалось создать полную копию. Проверьте свободное место и повторите':'Could not create a complete backup. Check available storage and try again.',
  'Проверяем файл копии…':'Checking backup…',
  'Восстанавливаем фотографии…':'Restoring photos…',
  'Сохраняем восстановленный мир…':'Saving restored story…',
  'Выберите слот. В старой копии отсутствуют фотографии.':'Choose a slot. This older backup did not include photos.',
  'Копия восстановлена. Выберите слот':'Backup restored. Choose a slot.',
  'Не удалось восстановить копию. Проверьте файл':'Could not restore this backup. Check the file.',
  'Игра не запущена':'The game could not start',
};

export function installToolbar(element) {
  let language = 'ru', status = 'Сохранения на этом устройстве';
  function badge(text) {
    status = text;
    element('storage-status').textContent = language === 'en' ? english[text] || text : text;
  }
  function update(locale, connected) {
    language = locale === 'en' ? 'en' : 'ru';
    document.documentElement.lang = language;
    const en = language === 'en';
    element('connect').textContent = connected ? (en ? 'RouterAI connected' : 'RouterAI подключён') : (en ? 'Connect RouterAI' : 'Подключить RouterAI');
    element('backup').textContent = en ? 'Download backup' : 'Скачать сохранения';
    element('import').textContent = en ? 'Restore backup' : 'Загрузить копию';
    element('fullscreen').setAttribute('aria-label',en ? 'Full screen' : 'Полный экран');
    badge(status);
  }
  return {badge, update};
}
