all: doc

doc: doc_man doc_html

doc_html: html-stamp

html-stamp: kantan.txt
	asciidoc -b xhtml11 -a icons -a toc -a numbered kantan.txt
	touch html-stamp

doc_man: man-stamp

man-stamp: kantan.txt
	asciidoc -d manpage -b docbook kantan.txt
	xsltproc /usr/share/xml/docbook/stylesheet/nwalsh/manpages/docbook.xsl kantan.xml
	touch man-stamp

doc_epub: epub-stamp

epub-stamp:
	a2x --icons -a toc -a toclevels=3 -a docinfo -f epub kantan.txt
	touch epub-stamp

doc_pdf: pdf-stamp

pdf-stamp:
	a2x --icons -a toc -a toclevels=3 -a docinfo -f pdf kantan.txt
	touch pdf-stamp

online: doc_html doc_epub doc_pdf
	scp kantan.html grml:/var/www/grml/kantan/index.html
	scp kantan.pdf  grml:/var/www/grml/kantan/
	scp kantan.epub grml:/var/www/grml/kantan/

clean:
	rm -f kantan.html kantan.xml kantan.8 kantan.epub kantan.pdf
	rm -f html-stamp man-stamp epub-stamp pdf-stamp
