const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const runtime = process.env.CANARYAAC_TEST_ROOT || 'C:/Users/Marlon/Documents/OT/.tools/canaryaac';
const template = fs.readFileSync(runtime + '/resources/view/admin/modules/client/index.html.twig', 'utf8');
const elements = new Map();

for (const match of template.matchAll(/<(textarea|input)\b[^>]*\bid="([^"]+)"[^>]*>/gi)) {
    elements.set(match[2], { tagName: match[1].toUpperCase() });
}

const document = {
    getElementById(id) {
        return elements.get(id) || null;
    },
};
const CKEDITOR = {
    replace(id) {
        const element = document.getElementById(id);
        assert.ok(element, `CKEditor target ${id} must exist on the Create Client page`);
        assert.equal(element.tagName, 'TEXTAREA', `CKEditor target ${id} must be a textarea`);
    },
};
const context = vm.createContext({ CKEDITOR, document });

for (const match of template.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)) {
    if (match[1].includes('CKEDITOR.replace')) {
        vm.runInContext(match[1], context, { filename: 'admin-client-inline-script.js' });
    }
}

console.log('PASS AdminClientEditor.Tests.js (Create Client CKEditor targets)');
