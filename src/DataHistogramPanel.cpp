/* Reverse Engineer's Hex Editor
 * Copyright (C) 2022 Daniel Collins <solemnwarning@solemnwarning.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 as published by
 * the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program; if not, write to the Free Software Foundation, Inc., 51
 * Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

#include "platform.hpp"

#include <assert.h>
#include <vector>
#include <wx/artprov.h>
#include <wx/axis/numberaxis.h>
#include <wx/xy/xyhistorenderer.h>
#include <wx/xy/xyplot.h>
#include <wx/xy/xysimpledataset.h>

#include "DataHistogramPanel.hpp"
#include "Events.hpp"

namespace REHex
{
	wxDEFINE_EVENT(DATAHISTOGRAM_BUCKET_SELECTED, wxCommandEvent);
	
	class DataHistogramDatasetAdapter : public XYDataset
	{
		public:
			DataHistogramDatasetAdapter(DataHistogramAccumulatorInterface *accumulator);
			virtual ~DataHistogramDatasetAdapter();
			
			virtual double GetX(size_t index, size_t serie) override;
			virtual double GetY(size_t index, size_t serie) override;
			virtual size_t GetSerieCount() override;
			virtual size_t GetCount(size_t serie) override;
			virtual wxString GetSerieName(size_t serie) override;
		
		private:
			DataHistogramAccumulatorInterface *accumulator;
	};
	
	class DataHistogramRenderer: public XYRenderer, public DrawObserver
	{
		public:
			DataHistogramRenderer(DataHistogramAccumulatorInterface *accumulator);
			virtual ~DataHistogramRenderer();
			
			void set_chart_panel(wxChartPanel *panel);
			void force_redraw();
			
			wxRect get_last_draw_rect();
			
			virtual void Draw(wxDC &dc, wxRect rc, Axis *horizAxis, Axis *vertAxis, XYDataset *dataset) override;
			virtual void NeedRedraw(DrawObject *obj) override;
			
		private:
			DataHistogramAccumulatorInterface *accumulator;
			wxChartPanel *panel;
			
			std::vector<wxRect> bucket_panel_rects;
			wxRect last_draw_rect;
			int mouse_over_bucket_idx;
			
			wxPoint mouse_down_point;
			
			int screen_point_to_bucket_idx(wxPoint point);
			
			void OnMotion(wxMouseEvent &event);
			void OnLeftDown(wxMouseEvent &event);
			void OnLeftUp(wxMouseEvent &event);
	};
};

REHex::DataHistogramDatasetAdapter::DataHistogramDatasetAdapter(DataHistogramAccumulatorInterface *accumulator):
	accumulator(accumulator) {}

REHex::DataHistogramDatasetAdapter::~DataHistogramDatasetAdapter() {}

double REHex::DataHistogramDatasetAdapter::GetX(size_t index, size_t serie)
{
	wxCHECK(serie < 1, 0);
	wxCHECK(index < accumulator->get_num_buckets(), 0);
	
	return index;
}

double REHex::DataHistogramDatasetAdapter::GetY(size_t index, size_t serie)
{
	wxCHECK(serie < 1, 0);
	wxCHECK(index < accumulator->get_num_buckets(), 0);
	
	return accumulator->get_bucket_count(index) + 1;
}

size_t REHex::DataHistogramDatasetAdapter::GetSerieCount()
{
	return 1;
}

size_t REHex::DataHistogramDatasetAdapter::GetCount(size_t serie)
{
	return accumulator->get_num_buckets();
}

wxString REHex::DataHistogramDatasetAdapter::GetSerieName(size_t serie)
{
	wxCHECK(serie < 1, wxEmptyString);
	return "hello";
}

REHex::DataHistogramRenderer::DataHistogramRenderer(DataHistogramAccumulatorInterface *accumulator):
	accumulator(accumulator),
	panel(NULL),
	mouse_over_bucket_idx(-1) {}

REHex::DataHistogramRenderer::~DataHistogramRenderer()
{
	set_chart_panel(NULL);
}

void REHex::DataHistogramRenderer::set_chart_panel(wxChartPanel *panel)
{
	if(this->panel != NULL)
	{
		this->panel->Unbind(wxEVT_LEFT_UP, &REHex::DataHistogramRenderer::OnLeftUp, this);
		this->panel->Unbind(wxEVT_LEFT_DOWN, &REHex::DataHistogramRenderer::OnLeftDown, this);
		this->panel->Unbind(wxEVT_MOTION, &REHex::DataHistogramRenderer::OnMotion, this);
	}
	
	this->panel = panel;
	
	if(this->panel != NULL)
	{
		panel->Bind(wxEVT_MOTION, &REHex::DataHistogramRenderer::OnMotion, this);
		panel->Bind(wxEVT_LEFT_DOWN, &REHex::DataHistogramRenderer::OnLeftDown, this);
		panel->Bind(wxEVT_LEFT_UP, &REHex::DataHistogramRenderer::OnLeftUp, this);
	}
}

void REHex::DataHistogramRenderer::force_redraw()
{
	FireNeedRedraw();
}

wxRect REHex::DataHistogramRenderer::get_last_draw_rect()
{
	return last_draw_rect;
}

void REHex::DataHistogramRenderer::Draw(wxDC &dc, wxRect rc, Axis *horizAxis, Axis *vertAxis, XYDataset *dataset)
{
	last_draw_rect = rc;
	
	assert(dataset->GetSerieCount() == 1);
	
	wxPoint screen_mouse_pos = wxGetMousePosition();
	wxPoint panel_mouse_pos = wxDefaultPosition;
	
	if(panel != NULL)
	{
		wxRect panel_screen_rect = panel->GetScreenRect();
		if(panel_screen_rect.Contains(screen_mouse_pos))
		{
			panel_mouse_pos = panel->ScreenToClient(screen_mouse_pos);
		}
	}
	
	bucket_panel_rects.resize(dataset->GetCount(0));
	mouse_over_bucket_idx = -1;
	
	FOREACH_DATAITEM(n, 0, dataset)
	{
		double xVal = n;
		double xNext = n + 1;
		double yVal = accumulator->get_bucket_count(n);
		
		if (!(horizAxis->IsVisible(xVal) || horizAxis->IsVisible(xNext)) || !vertAxis->IsVisible(yVal))
		{
			continue;
		}
		
		wxCoord xl = horizAxis->ToGraphics(dc, rc.x, rc.width, xVal);
		wxCoord xr = horizAxis->ToGraphics(dc, rc.x, rc.width, xNext);
		wxCoord y = vertAxis->ToGraphics(dc, rc.y, rc.height, yVal);
		
		bucket_panel_rects[n].x = xl;
		bucket_panel_rects[n].y = y;
		bucket_panel_rects[n].width = (xr - xl) + 1;
		bucket_panel_rects[n].height = rc.height - y + rc.y;
		
		dc.SetPen(*wxBLACK_PEN);
		
		if(bucket_panel_rects[n].Contains(panel_mouse_pos) && mouse_over_bucket_idx == -1)
		{
			mouse_over_bucket_idx = n;
			
			dc.SetBrush(*wxRED_BRUSH);
			
			std::string min_value_s = accumulator->get_bucket_min_value_as_string(n);
			std::string max_value_s = accumulator->get_bucket_max_value_as_string(n);
			std::string value_range_s = min_value_s != max_value_s
				? min_value_s + " - " + max_value_s
				: min_value_s;
			
			off_t count = accumulator->get_bucket_count(n);
			
			std::string s =
				"Value: " + value_range_s + "\n" +
				"Count: " + std::to_string(count);
			
			dc.DrawText(s, rc.x, rc.y);
		}
		else{
			dc.SetBrush(*wxGREEN_BRUSH);
		}
		
		dc.DrawRectangle(bucket_panel_rects[n]);
	}
}

void REHex::DataHistogramRenderer::NeedRedraw(DrawObject *obj)
{
    FireNeedRedraw();
}

int REHex::DataHistogramRenderer::screen_point_to_bucket_idx(wxPoint screen_point)
{
	if(panel != NULL)
	{
		wxRect panel_screen_rect = panel->GetScreenRect();
		if(panel_screen_rect.Contains(screen_point))
		{
			wxPoint panel_point = panel->ScreenToClient(screen_point);
			
			for(size_t i = 0; i < bucket_panel_rects.size(); ++i)
			{
				if(bucket_panel_rects[i].Contains(panel_point))
				{
					return i;
				}
			}
		}
	}
	
	return -1;
}

void REHex::DataHistogramRenderer::OnMotion(wxMouseEvent &event)
{
	wxPoint mouse_screen_point = wxGetMousePosition();
	int mouse_bucket_idx = screen_point_to_bucket_idx(mouse_screen_point);
	if(mouse_bucket_idx != mouse_over_bucket_idx)
	{
		FireNeedRedraw();
	}
	
	event.Skip();
}

void REHex::DataHistogramRenderer::OnLeftDown(wxMouseEvent &event)
{
	mouse_down_point = wxGetMousePosition();
	event.Skip();
}

void REHex::DataHistogramRenderer::OnLeftUp(wxMouseEvent &event)
{
	wxPoint mouse_point = wxGetMousePosition();
	if(mouse_point == mouse_down_point)
	{
		int bucket_idx = screen_point_to_bucket_idx(mouse_point);
		if(bucket_idx >= 0)
		{
			wxCommandEvent e(DATAHISTOGRAM_BUCKET_SELECTED);
			e.SetEventObject(panel);
			e.SetId(panel->GetId());
			e.SetInt(bucket_idx);
			
			panel->ProcessWindowEvent(e);
		}
	}
	
	event.Skip();
}

static REHex::ToolPanel *DataHistogramPanel_factory(wxWindow *parent, REHex::SharedDocumentPointer &document, REHex::DocumentCtrl *document_ctrl)
{
	return new REHex::DataHistogramPanel(parent, document, document_ctrl);
}

static REHex::ToolPanelRegistration tpr("DataHistogramPanel", "Histogram", REHex::ToolPanel::TPS_TALL, &DataHistogramPanel_factory);

enum {
	ID_WORD_SIZE_CHOICE = 1,
	ID_STRIDE_VALUE,
	ID_RANGE_CHOICE,
	ID_BUCKET_COUNT_CHOICE,
	ID_UP_BUTTON,
	ID_REFRESH_TIMER,
	
	WORD_SIZE_CHOICE_8BIT = 0,
	WORD_SIZE_CHOICE_16BIT,
	WORD_SIZE_CHOICE_32BIT,
	WORD_SIZE_CHOICE_64BIT,
};

BEGIN_EVENT_TABLE(REHex::DataHistogramPanel, wxPanel)
	EVT_CHOICE(ID_WORD_SIZE_CHOICE, REHex::DataHistogramPanel::OnWordSizeChanged)
	EVT_SPINCTRL(ID_STRIDE_VALUE, REHex::DataHistogramPanel::OnStrideChanged)
	EVT_COMMAND(ID_RANGE_CHOICE, EV_SELECTION_CHANGED, REHex::DataHistogramPanel::OnRangeChanged)
	EVT_CHOICE(ID_BUCKET_COUNT_CHOICE, REHex::DataHistogramPanel::OnBucketCountChanged)
	
	EVT_BUTTON(ID_UP_BUTTON, REHex::DataHistogramPanel::OnPopBucket)
	
	EVT_TIMER(ID_REFRESH_TIMER, REHex::DataHistogramPanel::OnRefreshTimer)
	
	EVT_COMMAND(wxID_ANY, DATAHISTOGRAM_BUCKET_SELECTED, REHex::DataHistogramPanel::OnBucketSelected)
END_EVENT_TABLE()

REHex::DataHistogramPanel::DataHistogramPanel(wxWindow *parent, SharedDocumentPointer &document, DocumentCtrl *document_ctrl):
	ToolPanel(parent),
	document(document),
	document_ctrl(document_ctrl),
	dataset(NULL),
	chart_panel(NULL),
	refresh_timer(this, ID_REFRESH_TIMER),
	wheel_accumulator(0),
	chart_panning(false)
{
	static const int MARGIN = 5;
	
	word_size_choice = new wxChoice(this, ID_WORD_SIZE_CHOICE);
	word_size_choice->Append("8-bit");
	word_size_choice->Append("16-bit");
	word_size_choice->Append("32-bit");
	word_size_choice->Append("64-bit");
	word_size_choice->SetSelection(WORD_SIZE_CHOICE_8BIT);
	
	stride_ctrl = new wxSpinCtrl(this, ID_STRIDE_VALUE);
	stride_ctrl->SetMaxSize(stride_ctrl->GetSizeFromTextSize(stride_ctrl->GetTextExtent("000")));
	
	stride_ctrl->SetRange(1, stride_ctrl->GetMax());
	stride_ctrl->SetValue(1);
	
	wxBoxSizer *sizer1 = new wxBoxSizer(wxHORIZONTAL);
	sizer1->Add(new wxStaticText(this, wxID_ANY, "Values:"), 0, wxALIGN_CENTER_VERTICAL);
	sizer1->Add(word_size_choice, 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	sizer1->Add(new wxStaticText(this, wxID_ANY, "Stride:"), 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	sizer1->Add(stride_ctrl, 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	sizer1->Add(new wxStaticText(this, wxID_ANY, "bytes"), 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	
	range_choice = new RangeChoiceLinear(this, ID_RANGE_CHOICE, document, document_ctrl);
	
	bucket_count_choice = new wxChoice(this, ID_BUCKET_COUNT_CHOICE);
	bucket_count_choice->Append("16");
	bucket_count_choice->Append("32");
	bucket_count_choice->Append("64");
	bucket_count_choice->Append("128");
	bucket_count_choice->Append("256");
	bucket_count_choice->SetSelection(0);
	
	wxBoxSizer *sizer2 = new wxBoxSizer(wxHORIZONTAL);
	sizer2->Add(new wxStaticText(this, wxID_ANY, "Range:"), 0, wxALIGN_CENTER_VERTICAL);
	sizer2->Add(range_choice, 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	sizer2->Add(new wxStaticText(this, wxID_ANY, "Buckets:"), 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	sizer2->Add(bucket_count_choice, 0, (wxLEFT | wxALIGN_CENTER_VERTICAL), MARGIN);
	
	wxBitmap bmp = wxArtProvider::GetBitmap(wxART_GO_DIR_UP, wxART_BUTTON);
	up_button = new wxBitmapButton(this, ID_UP_BUTTON, bmp);
	
	wxBoxSizer *sizer = new wxBoxSizer(wxVERTICAL);
	sizer->Add(sizer1, 0, (wxLEFT | wxRIGHT | wxTOP), MARGIN);
	sizer->Add(sizer2, 0, (wxLEFT | wxRIGHT | wxTOP), MARGIN);
	sizer->Add(up_button, 0, (wxLEFT | wxRIGHT | wxTOP), MARGIN);
	SetSizerAndFit(sizer);
	
	reset_accumulator();
}

REHex::DataHistogramPanel::~DataHistogramPanel() {}

std::string REHex::DataHistogramPanel::name() const
{
	return "DataHistogramPanel";
}

void REHex::DataHistogramPanel::save_state(wxConfig *config) const
{
	/* TODO */
}

void REHex::DataHistogramPanel::load_state(wxConfig *config)
{
	/* TODO */
}

wxSize REHex::DataHistogramPanel::DoGetBestClientSize() const
{
	/* TODO */
	return wxSize(100, -1);
}

void REHex::DataHistogramPanel::update()
{
	if (!is_visible)
	{
		/* There is no sense in updating this if we are not visible */
		return;
	}
	
	#if 0
	if(update_needed && document_ctrl)
	{
		size_t strings_count;
		
		{
			std::lock_guard<std::mutex> sl(strings_lock);
			
			strings_count = strings.size();
			update_needed = false;
		}
		
		list_ctrl->SetItemCount(strings_count);
		
		bool searching = spawned_threads > 0;
		std::string status_text = "";
		
		if(searching)
		{
			status_text += "Searching from " + format_offset(search_base, document_ctrl->get_offset_display_base(), document->buffer_length());
			continue_button->Disable();
		}
		else{
			status_text += "Searched from " + format_offset(search_base, document_ctrl->get_offset_display_base(), document->buffer_length());
			
			auto next_pending = pending.find_first_in(search_base, std::numeric_limits<off_t>::max());
			continue_button->Enable(next_pending != pending.end());
		}
		
		status_text += "\n";
		
		if(strings_count > 0)
		{
			status_text += "Found "
				+ wxNumberFormatter::ToString((long)(strings_count))
				+ " strings";
		}
		else if(!searching)
		{
			status_text += "No strings found";
		}
		
		this->status_text->SetLabelText(status_text);
	}
	#endif
	
	//reset_chart();
}

void REHex::DataHistogramPanel::reset_accumulator()
{
	int bucket_count = 16 << bucket_count_choice->GetSelection();
	int stride = stride_ctrl->GetValue();
	
	accumulators.clear();
	
	off_t range_offset, range_length;
	std::tie(range_offset, range_length) = range_choice->get_range();
	
	switch(word_size_choice->GetSelection())
	{
		case WORD_SIZE_CHOICE_8BIT:
			accumulators.emplace_back(new DataHistogramAccumulator<uint8_t>(document, range_offset, stride, range_length, bucket_count));
			break;
		
		case WORD_SIZE_CHOICE_16BIT:
			accumulators.emplace_back(new DataHistogramAccumulator<uint16_t>(document, range_offset, stride, range_length, bucket_count));
			break;
		
		case WORD_SIZE_CHOICE_32BIT:
			accumulators.emplace_back(new DataHistogramAccumulator<uint32_t>(document, range_offset, stride, range_length, bucket_count));
			break;
		
		case WORD_SIZE_CHOICE_64BIT:
			accumulators.emplace_back(new DataHistogramAccumulator<uint64_t>(document, range_offset, stride, range_length, bucket_count));
			break;
		
		default:
			/* Unreachable. */
			return;
	}
	
	reset_chart();
}

void REHex::DataHistogramPanel::reset_chart()
{
	// First step: create the plot.
	XYPlot *plot = new XYPlot();
	
	// Second step: create the dataset.
	DataHistogramDatasetAdapter *dataset = new DataHistogramDatasetAdapter(accumulators.back().get());
	this->dataset = dataset;
	
	renderer = new DataHistogramRenderer(accumulators.back().get());
	dataset->SetRenderer(renderer);
	
	// add our dataset to plot
	plot->AddDataset(dataset);
	
	// add left and bottom number axes
	NumberAxis *leftAxis = new NumberAxis(AXIS_LEFT);
	leftAxis->IntegerValues(true);
	
	x_axis = new NumberAxis(AXIS_BOTTOM);
	x_axis->SetFixedBounds(0, accumulators.back()->get_num_buckets());
	x_axis->SetTickFormat("");
	
	// set bottom axis margins
	x_axis->SetMargins(15, 15);
	
	x_axis->SetWindowWidth(accumulators.back()->get_num_buckets());
	x_axis->SetUseWindow(true);
	
	// add axes to plot
	plot->AddAxis(leftAxis);
	plot->AddAxis(x_axis);
	
	// link axes and dataset
	plot->LinkDataVerticalAxis(0, 0);
	plot->LinkDataHorizontalAxis(0, 0);
	
	// and finally create chart
	Chart *chart = new Chart(plot, wxEmptyString);
	
	if(chart_panel != NULL)
	{
		GetSizer()->Detach(chart_panel);
		
		/* Don't destroy the old wxChartPanel yet in case we are running inside one of its
		 * event handlers.
		*/
		wxWindow *old_chart_panel = chart_panel;
		CallAfter([old_chart_panel]()
		{
			old_chart_panel->Destroy();
		});
	}
	
	// Create a chart panel to display the chart.
	chart_panel = new wxChartPanel(this, wxID_ANY, chart);
	GetSizer()->Add(chart_panel, 1, (wxLEFT | wxRIGHT | wxTOP | wxEXPAND), 5);
	GetSizer()->Layout();
	
	chart_panel->Bind(wxEVT_MOUSEWHEEL, &REHex::DataHistogramPanel::OnChartWheel, this);
	chart_panel->Bind(wxEVT_LEFT_DOWN, &REHex::DataHistogramPanel::OnChartLeftDown, this);
	chart_panel->Bind(wxEVT_LEFT_UP, &REHex::DataHistogramPanel::OnChartLeftUp, this);
	chart_panel->Bind(wxEVT_MOTION, &REHex::DataHistogramPanel::OnChartMotion, this);
	
	renderer->set_chart_panel(chart_panel);
	
	refresh_timer.Start(500, wxTIMER_ONE_SHOT);
}

wxRect REHex::DataHistogramPanel::get_chart_panel_rect()
{
	assert(renderer != NULL);
	return renderer->get_last_draw_rect();
}

wxRect REHex::DataHistogramPanel::get_chart_screen_rect()
{
	wxRect r = get_chart_panel_rect();
	
	wxPoint r_screen_base = chart_panel->ClientToScreen(wxPoint(r.x, r.y));
	
	r.x = r_screen_base.x;
	r.y = r_screen_base.y;
	
	return r;
}

void REHex::DataHistogramPanel::OnWordSizeChanged(wxCommandEvent &event)
{
	static const int WORD_SIZES[] = { 1, 2, 4, 8 };
	int word_size_bytes = WORD_SIZES[ word_size_choice->GetSelection() ];
	
	stride_ctrl->SetRange(word_size_bytes, stride_ctrl->GetMax());
	stride_ctrl->SetValue(word_size_bytes);
	
	reset_accumulator();
}

void REHex::DataHistogramPanel::OnStrideChanged(wxSpinEvent &event)
{
	reset_accumulator();
}

void REHex::DataHistogramPanel::OnRangeChanged(wxCommandEvent &event)
{
	reset_accumulator();
}

void REHex::DataHistogramPanel::OnBucketCountChanged(wxCommandEvent &event)
{
	reset_accumulator();
}

void REHex::DataHistogramPanel::OnRefreshTimer(wxTimerEvent &event)
{
	if(accumulators.back()->get_progress() != 1.0)
	{
		refresh_timer.Start(-1, wxTIMER_ONE_SHOT);
	}
	
	dataset->DatasetChanged();
}

void REHex::DataHistogramPanel::OnBucketSelected(wxCommandEvent &event)
{
	int bucket_idx = event.GetInt();
	
	DataHistogramAccumulatorInterface *new_accumulator = accumulators.back()->subdivide_bucket(bucket_idx);
	if(new_accumulator != NULL)
	{
		/* TODO: Stop processing previous accumulator. */
		
		accumulators.emplace_back(new_accumulator);
		reset_chart();
	}
}

void REHex::DataHistogramPanel::OnPopBucket(wxCommandEvent &event)
{
	if(accumulators.size() > 1)
	{
		accumulators.pop_back();
		reset_chart();
	}
}

void REHex::DataHistogramPanel::OnChartWheel(wxMouseEvent &event)
{
	wxMouseWheelAxis axis = event.GetWheelAxis();
	
	wxPoint screen_point = wxGetMousePosition();
	wxRect chart_screen_rect = get_chart_screen_rect();
	
	double chart_width = x_axis->GetWindowWidth();
	double chart_xpos  = x_axis->GetWindowPosition();
	
	/* Zoom on the mouse position (if inside chart boundaries), otherwise zoom on the center
	 * of the visible area.
	*/
	
	double data_x_value = chart_xpos + (chart_width / 2);
	
	if(chart_screen_rect.Contains(screen_point))
	{
		wxWindowDC dc(chart_panel);
		
		wxPoint panel_point = chart_panel->ScreenToClient(screen_point);
		wxRect chart_panel_rect = get_chart_panel_rect();
		
		data_x_value = x_axis->ToData(dc, chart_panel_rect.x, chart_panel_rect.width, panel_point.x);
	}
	
	if(axis == wxMOUSE_WHEEL_VERTICAL)
	{
		int delta = event.GetWheelDelta();
		
		wheel_accumulator += event.GetWheelRotation();
		
		if(wheel_accumulator >= delta)
		{
			chart_width -= (chart_width / 2) * (wheel_accumulator / delta);
		}
		else if(wheel_accumulator <= delta)
		{
			chart_width -= (chart_width / 2) * (wheel_accumulator / delta);
		}
		else{
			return;
		}
		
		wheel_accumulator %= delta;
		
		chart_width = std::min(chart_width, (double)(accumulators.back()->get_num_buckets()));
		chart_width = std::max(chart_width, 4.0);
		
		chart_xpos = data_x_value - (chart_width / 2);
		
		chart_xpos = std::min(chart_xpos, (double)(accumulators.back()->get_num_buckets() - chart_width));
		chart_xpos = std::max(chart_xpos, 0.0);
		
		x_axis->SetWindowWidth(chart_width);
		x_axis->SetWindowPosition(chart_xpos);
	}
}

void REHex::DataHistogramPanel::OnChartLeftDown(wxMouseEvent &event)
{
	mouse_down_point = wxGetMousePosition();
	chart_panning = false;
	event.Skip();
}

void REHex::DataHistogramPanel::OnChartLeftUp(wxMouseEvent &event)
{
	chart_panning = false;
	event.Skip();
}

void REHex::DataHistogramPanel::OnChartMotion(wxMouseEvent &event)
{
	wxRect chart_screen_rect = get_chart_screen_rect();
	
	if(event.Dragging() && chart_screen_rect.Contains(mouse_down_point))
	{
		wxPoint mouse_screen_point = wxGetMousePosition();
		
		if(!chart_panning)
		{
			int drag_x = wxSystemSettings::GetMetric(wxSYS_DRAG_X);
			int drag_y = wxSystemSettings::GetMetric(wxSYS_DRAG_Y);
			
			if(abs(mouse_down_point.x - mouse_screen_point.x) > drag_x || abs(mouse_screen_point.y - mouse_screen_point.y) > drag_y)
			{
				mouse_last_point = mouse_down_point;
				chart_panning = true;
			}
		}
		
		if(chart_panning)
		{
			int adj_x = mouse_last_point.x - mouse_screen_point.x;
			
			double chart_width = x_axis->GetWindowWidth();
			double chart_xpos  = x_axis->GetWindowPosition();
			
			double chart_xpos_per_pixel = chart_width / (double)(chart_screen_rect.width);
			
			chart_xpos += (double)(adj_x) * chart_xpos_per_pixel;
			
			chart_xpos = std::min(chart_xpos, (double)(accumulators.back()->get_num_buckets() - chart_width));
			chart_xpos = std::max(chart_xpos, 0.0);
			
			x_axis->SetWindowPosition(chart_xpos);
		}
		
		mouse_last_point = mouse_screen_point;
		
		return;
	}
	
	event.Skip();
}

// void REHex::DataHistogramPanel::OnDataModifying(OffsetLengthEvent &event)
// {
// 	pause_threads();
// 	
// 	/* Continue propogation. */
// 	event.Skip();
// }
// 
// void REHex::DataHistogramPanel::OnDataModifyAborted(OffsetLengthEvent &event)
// {
// 	start_threads();
// 	
// 	/* Continue propogation. */
// 	event.Skip();
// }
// 
// void REHex::DataHistogramPanel::OnDataErase(OffsetLengthEvent &event)
// {
// 	{
// 		std::lock_guard<std::mutex> sl(strings_lock);
// 		strings.data_erased(event.offset, event.length);
// 	}
// 	
// 	{
// 		std::lock_guard<std::mutex> pl(pause_lock);
// 		
// 		dirty.data_erased(event.offset, event.length);
// 		pending.data_erased(event.offset, event.length);
// 		assert(working.empty());
// 		
// 		mark_dirty_pad(event.offset, 0);
// 	}
// 	
// 	start_threads();
// 	
// 	/* Continue propogation. */
// 	event.Skip();
// }
// 
// void REHex::DataHistogramPanel::OnDataInsert(OffsetLengthEvent &event)
// {
// 	{
// 		std::lock_guard<std::mutex> sl(strings_lock);
// 		strings.data_inserted(event.offset, event.length);
// 	}
// 	
// 	{
// 		std::lock_guard<std::mutex> pl(pause_lock);
// 		
// 		dirty.data_inserted(event.offset, event.length);
// 		pending.data_inserted(event.offset, event.length);
// 		assert(working.empty());
// 		
// 		mark_dirty_pad(event.offset, event.length);
// 	}
// 	
// 	start_threads();
// 	
// 	/* Continue propogation. */
// 	event.Skip();
// }
// 
// void REHex::DataHistogramPanel::OnDataOverwrite(OffsetLengthEvent &event)
// {
// 	{
// 		std::lock_guard<std::mutex> pl(pause_lock);
// 		mark_dirty_pad(event.offset, event.length);
// 	}
// 	
// 	start_threads();
// 	
// 	/* Continue propogation. */
// 	event.Skip();
// }
