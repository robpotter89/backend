from mediawords.annotator.store import JSONAnnotationStore
from mediawords.util.log import create_logger

log = create_logger(__name__)


class NYTLabelsAnnotatorStore(JSONAnnotationStore):
    """NYTLabels annotator store."""

    def __init__(self):
        super().__init__(raw_annotations_table='nytlabels_annotations')
