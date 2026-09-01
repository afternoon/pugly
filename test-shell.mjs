import fs from 'fs';
import { JSDOM } from 'jsdom';
import * as lipsMod from 'lips';
await lipsMod.bootstrap('./node_modules/lips/dist/std.xcb');

const html = fs.readFileSync('/mnt/user-data/outputs/live-scheme-builder.html', 'utf8');
const dom = new JSDOM(html, { runScripts: 'outside-only' });
const w = dom.window;
w.lips = Object.assign(Object.create(null), lipsMod, { bootstrap: () => Promise.resolve() });
// the inline shell script is the last <script> without src
const shell = Array.from(w.document.querySelectorAll('script'))
  .filter(s => !s.src && s.type !== 'text/scheme').pop().textContent;
w.eval(shell);

const wait = (ms) => new Promise(r => setTimeout(r, ms));
await wait(400);

let pass = 0, fail = 0;
const check = (name, got, want) => {
  if (got === want) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n     got:  ' + got + '\n     want: ' + want); }
};
const $ = (s) => w.document.querySelector(s);

check('status ok', $('#status').className, 'ok');
check('seeded main rendered', $('#preview').innerHTML, '<div>hello</div>');

// edit main -> counter, register
$('#editor').value = `
(define-component! 'main
  (lambda ()
    (let ((n (state '(counter n) 0)))
      \`(div (span ,(lambda () (number->string (n))))
            (button (@ (on-click ,(lambda (e) (state-set! '(counter n) (+ (n) 1))))) "+1")))))`;
$('#register').dispatchEvent(new w.MouseEvent('click'));
await wait(300);
check('counter registered', $('#preview').innerHTML, '<div><span>0</span><button>+1</button></div>');

$('#preview button').dispatchEvent(new w.MouseEvent('click'));
$('#preview button').dispatchEvent(new w.MouseEvent('click'));
check('two clicks', $('#preview span').textContent, '2');

// redefine with new markup; state must survive
$('#editor').value = `
(define-component! 'main
  (lambda ()
    (let ((n (state '(counter n) 0)))
      \`(div (span ,(lambda () (string-append "count: " (number->string (n)))))
            (button (@ (on-click ,(lambda (e) (state-set! '(counter n) (+ (n) 1))))) "+1")))))`;
$('#register').dispatchEvent(new w.MouseEvent('click'));
await wait(300);
check('redefine keeps state', $('#preview span').textContent, 'count: 2');
$('#preview button').dispatchEvent(new w.MouseEvent('click'));
check('still reactive', $('#preview span').textContent, 'count: 3');

// inspector
$('#refresh').dispatchEvent(new w.MouseEvent('click'));
await wait(200);
check('tree has effects', $('#tree').textContent.includes('effect'), true);

// repl
$('#tab-repl').dispatchEvent(new w.MouseEvent('click'));
$('#replin').value = "((state '(counter n) 0))";
$('#replin').dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Enter' }));
await wait(300);
check('repl reads live state', $('#replout').textContent.includes('3'), true);

// repl can redefine a component live
$('#replin').value = "(define-component! 'main (lambda () `(em \"from repl\")))";
$('#replin').dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Enter' }));
await wait(300);
check('repl redefine re-renders', $('#preview').innerHTML, '<em>from repl</em>');

// dump
$('#dump').dispatchEvent(new w.MouseEvent('click'));
check('dump writes source', $('#editor').value.includes('define-component!'), true);

// error path
$('#editor').value = `(define-component! 'main (lambda () (car '())))`;
$('#register').dispatchEvent(new w.MouseEvent('click'));
await wait(300);
check('bad component isolated, app alive', $('#status').className, 'ok');
$('#editor').value = `(define-component! 'main (lambda () \`(p "recovered")))`;
$('#register').dispatchEvent(new w.MouseEvent('click'));
await wait(300);
check('recovers after error', $('#preview').innerHTML, '<p>recovered</p>');

console.log(`\n${pass} passed, ${fail} failed`);
