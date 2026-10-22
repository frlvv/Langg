import Foundation
import Testing
import LanggCore
@testable import Langg

private let referenceEnglish = """
hello world cat dog house home work word text book time day night morning evening people person friend family
mother father sister brother child children school university teacher student class room table chair window door
computer keyboard screen mouse phone message email letter paper page story question answer problem solution example
language english russian music movie game food water tea coffee milk bread cheese apple orange banana potato tomato
car bus train plane road street city town country river sea mountain forest tree flower garden weather rain snow
sun moon star light dark red green blue black white yellow color small large big short long new old good bad
happy sad fast slow easy hard simple clear clean beautiful right left up down front back open close start stop
read write speak listen learn think know make give take find help love like look come go run walk sleep eat drink
one two three four five six seven eight nine ten yes no please thanks today tomorrow yesterday now later never
always often sometimes again first second last next before after inside outside together only also very more less
""".split(whereSeparator: \.isWhitespace).map(String.init)

private let referenceRussian = """
привет мир кот кошка собака дом работа слово текст книга время день ночь утро вечер человек люди друг семья
мама папа сестра брат ребёнок дети школа университет учитель студент класс комната стол стул окно дверь
компьютер клавиатура экран мышь телефон сообщение письмо бумага страница история вопрос ответ проблема решение
пример язык русский музыка фильм игра еда вода чай кофе молоко хлеб сыр яблоко апельсин банан картошка помидор
машина автобус поезд самолёт дорога улица город страна река море гора лес дерево цветок сад погода дождь снег
солнце луна звезда свет красный зелёный синий чёрный белый жёлтый цвет маленький большой короткий длинный новый
старый хороший плохой счастливый быстрый медленный простой понятный чистый красивый правый левый верх низ
читать писать говорить слушать учиться думать знать делать дать взять найти помочь любить смотреть идти бежать
спать есть пить один два три четыре пять шесть семь восемь девять десять да нет пожалуйста спасибо сегодня
завтра вчера сейчас потом никогда всегда часто иногда снова первый второй последний следующий раньше позже
внутри снаружи вместе только тоже очень больше меньше любовь счастье жизнь ничего что это как так тут там
хат хлеб ёж ёлка ещё уже всё все мой твой наш ваш
""".split(whereSeparator: \.isWhitespace).map(String.init)

@MainActor @Test func correctWordsInReferenceCorpusAreNeverChanged() async {
    let words = referenceEnglish + referenceRussian
    #expect(words.count >= 200)
    let spelling = SpellingService()
    for word in words {
        let text = word + " "
        for candidate in AutomaticCorrection.candidates(in: text, caretUTF16: text.utf16.count) {
            let source = candidate.sourceNeedsDictionaryCheck
                ? await spelling.isKnown(candidate.original, language: candidate.direction.sourceLanguage) : false
            let target = await spelling.isKnown(candidate.replacement, language: candidate.direction.targetLanguage)
            #expect(!AutomaticCorrection.shouldCorrect(candidate, sourceKnown: source, targetKnown: target), "Correct word: \(word)")
        }
    }
}

@Test func referenceCorpusRoundTripsPhysicalKeysIncludingCase() throws {
    for word in referenceRussian {
        for original in [word, word.uppercased(), word.capitalized] {
            let english = try #require(LayoutConverter.convert(original, direction: .russianToEnglish))
            #expect(LayoutConverter.convert(english, direction: .englishToRussian, punctuation: .physicalKeys) == original)
        }
    }
}
